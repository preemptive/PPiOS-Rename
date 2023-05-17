// -*- mode: ObjC -*-

/*************************************************
  Copyright 2016-2018 PreEmptive Solutions, LLC
  See LICENSE.txt for licensing information
*************************************************/
  
//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2015 Steve Nygard.

#import "CDClassDump.h"

#import "CDFatArch.h"
#import "CDFatFile.h"
#import "CDLCDylib.h"
#import "CDMachOFile.h"
#import "CDObjectiveCProcessor.h"
#import "CDVisitor.h"
#import "CDTypeController.h"
#import "CDSearchPathState.h"
#import "CDXibStoryBoardProcessor.h"
#import "CDSymbolsGeneratorVisitor.h"

NSString *CDErrorDomain_ClassDump = @"CDErrorDomain_ClassDump";

NSString *CDErrorKey_Exception    = @"CDErrorKey_Exception";

@interface NSString (LocalNSStringExtensions)
- (NSString *)absolutePath;
@end

@implementation NSString (LocalNSStringExtensions)
- (NSString *)absolutePath
{
    if ([self hasPrefix:@"/"]) {
        return self;
    }

    NSString *currentDirectory = [[NSFileManager new] currentDirectoryPath];
    NSString *filename = [NSString stringWithFormat:@"%@/%@", currentDirectory, self];
    filename = [filename stringByStandardizingPath];
    return filename;
}
@end


// Category to wrap the C-struct CDArch in an NSValue
@interface NSValue (CDArch)
+ (id)valueOf:(CDArch)arch;
- (CDArch)arch;
@end

@implementation NSValue (CDArch)
+ (id)valueOf:(CDArch)arch
{
    return [NSValue value:&arch withObjCType:@encode(CDArch)];
}

- (CDArch)arch
{
    CDArch value;
    [self getValue:&value];
    return value;
}
@end


@interface CDClassDump ()
@end

#pragma mark -

@implementation CDClassDump
{
    CDSearchPathState *_searchPathState;
    
    NSString *_sdkRoot;
    NSMutableArray *_machOFiles;
    NSMutableDictionary *_machOFilesByName;
    NSMutableArray *_objcProcessors;
    
    CDTypeController *_typeController;
    
    CDArch _targetArch;
}

static NSDictionary<NSValue *, NSArray<NSValue *> *> *supportedArches = nil;

+ (NSValue *)archFor:(NSString *)name
{
    return [NSValue valueOf:CDArchFromName(name)];
}

+ (void)addEntryTo:(NSMutableDictionary<NSValue *, NSArray<NSValue *> *> *)dictionary
           forArch:(NSString *)arch
        candidates:(NSString *)first, ... // "candidates" not "alternatives", since it could be same
{
    NSMutableArray *candidateArray = [NSMutableArray new];
    [candidateArray addObject:[self archFor:first]];

    id candidate;
    va_list argumentList;
    va_start(argumentList, first);
    while ((candidate = va_arg(argumentList, NSObject *))) {
        [candidateArray addObject:[self archFor:candidate]];
    }
    va_end(argumentList);

    dictionary[[self archFor:arch]] = [NSArray arrayWithArray:candidateArray];
}

+ (NSDictionary<NSValue *, NSArray<NSValue *> *> *)getSupportedArches
{
    if (supportedArches == nil) {
        NSMutableDictionary<NSValue *, NSArray<NSValue *> *> *arches = [NSMutableDictionary new];
        [self addEntryTo:arches forArch:@"armv7" candidates:@"armv7", @"x86_64", @"i386", nil];
        [self addEntryTo:arches forArch:@"armv7s" candidates:@"armv7s", @"x86_64", @"i386", nil];
        [self addEntryTo:arches forArch:@"arm64" candidates:@"arm64", @"x86_64", @"i386", nil];
        [self addEntryTo:arches forArch:@"i386" candidates:@"i386", @"x86_64", nil];
        [self addEntryTo:arches forArch:@"x86_64" candidates:@"x86_64", @"i386", nil];
        supportedArches = [NSDictionary dictionaryWithDictionary:arches];
    }

    return supportedArches;
}

- (id)init;
{
    if ((self = [super init])) {
        _searchPathState = [[CDSearchPathState alloc] init];
        _sdkRoot = nil;
        
        _machOFiles = [[NSMutableArray alloc] init];
        _machOFilesByName = [[NSMutableDictionary alloc] init];
        _objcProcessors = [[NSMutableArray alloc] init];
        
        _typeController = [[CDTypeController alloc] initWithClassDump:self];
        
        // These can be ppc, ppc7400, ppc64, i386, x86_64
        _targetArch.cputype = CPU_TYPE_ANY;
        _targetArch.cpusubtype = 0;
    }

    return self;
}

- (BOOL)containsObjectiveCData;
{
    for (CDObjectiveCProcessor *processor in self.objcProcessors) {
        if ([processor hasObjectiveCData])
            return YES;
    }

    return NO;
}

- (BOOL)hasEncryptedFiles;
{
    for (CDMachOFile *machOFile in self.machOFiles) {
        if ([machOFile isEncrypted]) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)hasObjectiveCRuntimeInfo;
{
    return self.containsObjectiveCData || self.hasEncryptedFiles;
}

- (BOOL)loadFile:(CDFile *)file error:(NSError **)error depth:(int)depth {
    NSValue *archObject = [NSValue valueOf:_targetArch];
    NSArray<NSValue *> *candidates = [[self class] getSupportedArches][archObject];
    if (candidates == nil) {
        // if no alternatives have been specified for the target architecture, only allow the target
        candidates = @[archObject];
    }

    CDMachOFile *machOFile = nil;
    for (NSValue *alternative in candidates) {
        machOFile = [file machOFileWithArch:alternative.arch];
        if (machOFile != nil)
            break;
    }

    if (machOFile == nil) {
        if (error != NULL) {
            NSString *failureReason;
            NSString *targetArchName = CDNameForCPUType(_targetArch.cputype, _targetArch.cpusubtype);
            if ([file isKindOfClass:[CDFatFile class]] && [(CDFatFile *)file containsArchitecture:_targetArch]) {
                failureReason = [NSString stringWithFormat:(@"Fat file does not contain a valid Mach-O binary for the "
                                                            @"specified architecture (%@). " @STATIC_LIBRARY_MESSAGE),
                                          targetArchName];
            } else {
                failureReason = [NSString stringWithFormat:@"File doesn't contain the specified architecture (%@).  Available architectures are %@.", targetArchName, file.architectureNameDescription];
            }
            NSDictionary *userInfo = @{ NSLocalizedFailureReasonErrorKey : failureReason };
            *error = [NSError errorWithDomain:CDErrorDomain_ClassDump code:0 userInfo:userInfo];
        }
        return NO;
    }

    // Set before processing recursively.  This was getting caught on CoreUI on 10.6
    assert([machOFile filename] != nil);
    [_machOFiles addObject:machOFile];
    _machOFilesByName[machOFile.filename] = machOFile;

    BOOL shouldProcessRecursively = YES;

    if (shouldProcessRecursively) {
        @try {
            for (CDLoadCommand *loadCommand in [machOFile loadCommands]) {
                if ([loadCommand isKindOfClass:[CDLCDylib class]]) {
                    CDLCDylib *dylibCommand = (CDLCDylib *)loadCommand;
                    int command = [dylibCommand cmd];

                    // More commands may need to be added to this list as the SDKs that ship with Xcode change, but for
                    // now this should be sufficient.
                    if ((command == LC_LOAD_DYLIB)
                            || (command == LC_REEXPORT_DYLIB)
                            || (command == LC_LOAD_WEAK_DYLIB)) {
                        [self.searchPathState pushSearchPaths:[machOFile runPaths]];
                        {
                            NSString *loaderPathPrefix = @"@loader_path";
                            
                            NSString *path = [dylibCommand path];
                            if ([path hasPrefix:loaderPathPrefix]) {
                                NSString *loaderPath = [machOFile.filename stringByDeletingLastPathComponent];
                                path = [[path stringByReplacingOccurrencesOfString:loaderPathPrefix withString:loaderPath] stringByStandardizingPath];
                                
                            } else {
                                
                                // First of all, God bless me for fixing this stupid issue and hopefully, the owner of this repo will fix the problem fundamentally 🚀 🎉
                                // Fixing issue#39 : https://github.com/preemptive/PPiOS-Rename/issues/39 🪲
                                // Why do we need to do these f...g workaround? 🦧
                                // because It's so common for Apple to ruin our life 😩
                                // Many things have been changed on the DYLIB files in the new releases so we need to use the old files 🤷🏻‍♂️
                                // Thanks to the @BillBai that who motivated me to debug this issue with the following response🫡:
    
                                /*
                                This is because the iOS SDK's frameworks binaries from newer version of Xcode are using chained fixups and export trie Mach-O load commands to encode bind/rebase and symbol info. Not the dyld info in the older version. And the ppios-rename does not support these load commands yet.

                                A quick fix is just download the older version of Xcode (https://xcodereleases.com) ,and use the older version sdk by passing the "--sdk-root" argument.
                                
                                */
                                
                                
                                // I've added old files to a bundle and read them for this particular DYLIB file. 🥳
                                // We received the error "Unknown load command: 0x80000033" because of these 3 dylibs files even though we passed the old Xcode path as --sdk-root params in our command.
                                //You might need to add more dylibs files depending on your project requirements. ( You still need to pass the iPhoneOS.sdk path from the old Xcode (e.g 11-12)
                                
                                if ([path containsString:@"/usr/lib/system/libsystem_kernel.dylib"]) {
                                    path = [self getFilePathForPPiOSBundle:@"libsystem_kernel.dylib"];
                                } else if ([path isEqualToString:@"/usr/lib/system/libsystem_platform.dylib"]) {
                                    path = [self getFilePathForPPiOSBundle:@"libsystem_platform.dylib"];
                                } else if ([path isEqualToString:@"/usr/lib/system/libsystem_pthread.dylib"]) {
                                    path = [self getFilePathForPPiOSBundle:@"libsystem_pthread.dylib"];
                                }
                            }
                            
                            // My $1 tip to you guys:  you can find what libraries causing "Unknown load command: 0x80000033" by uncommenting the next line and find it in the terminal windows
                            
                            // NSLog(@"MoLowKey-Debug : %@ \n",path);
                            [self machOFileWithName:path andDepth:depth+1]; // Loads as a side effect
                        }
                        [self.searchPathState popSearchPaths];
                    }
                }
            }
        }
        @catch (NSException *exception) {
            NSLog(@"Caught exception: %@", exception);
            if (error != NULL) {
                NSDictionary *userInfo = @{
                NSLocalizedFailureReasonErrorKey : @"Caught exception",
                CDErrorKey_Exception             : exception,
                };
                *error = [NSError errorWithDomain:CDErrorDomain_ClassDump code:0 userInfo:userInfo];
            }
            return NO;
        }
    }

    return YES;
}

#pragma mark -

- (int)processObjectiveCData;
{
    for (CDMachOFile *machOFile in self.machOFiles) {
        CDObjectiveCProcessor *processor = [[[machOFile processorClass] alloc] initWithMachOFile:machOFile];
        int result = [processor process];
        if (result != 0) {
            return result;
        }
        [_objcProcessors addObject:processor];
    }
    
    return 0;
}

// This visits everything segment processors, classes, categories.  It skips over modules.  Need something to visit modules so we can generate separate headers.
- (void)recursivelyVisit:(CDVisitor *)visitor;
{
    [visitor willBeginVisiting];

    NSEnumerator *objcProcessors;
    objcProcessors = [self.objcProcessors reverseObjectEnumerator];

    for (CDObjectiveCProcessor *processor in objcProcessors) {
        [processor recursivelyVisit:visitor];
    }

    [visitor didEndVisiting];
}

- (CDMachOFile *)machOFileWithName:(NSString *)name andDepth:(int)depth {
    NSString *adjustedName = nil;
    NSString *executablePathPrefix = @"@executable_path";
    NSString *rpathPrefix = @"@rpath";

    if ([name hasPrefix:executablePathPrefix]) {
        adjustedName = [name stringByReplacingOccurrencesOfString:executablePathPrefix withString:self.searchPathState.executablePath];
    } else if ([name hasPrefix:rpathPrefix]) {
        //NSLog(@"Searching for %@ through run paths: %@", name, [searchPathState searchPaths]);
        for (NSString *searchPath in [self.searchPathState searchPaths]) {
            NSString *str = [name stringByReplacingOccurrencesOfString:rpathPrefix withString:searchPath];
            //NSLog(@"trying %@", str);
            if ([[NSFileManager defaultManager] fileExistsAtPath:str]) {
                adjustedName = str;
                //NSLog(@"Found it!");
                break;
            }
        }
        if (adjustedName == nil) {
            adjustedName = name;
            //NSLog(@"Did not find it.");
        }
    } else if (self.sdkRoot != nil) {
        NSString *pathInSDK = [self.sdkRoot stringByAppendingPathComponent:name];
        
        // Some libraries cannot be provided by the SDK, they must come from the host system.
        adjustedName = [[NSFileManager defaultManager] fileExistsAtPath:pathInSDK] ? pathInSDK : name;
    } else {
        adjustedName = name;
    }

    CDMachOFile *machOFile = _machOFilesByName[adjustedName];
    if (machOFile == nil) {
        CDFile *file = [CDFile fileWithContentsOfFile:adjustedName searchPathState:self.searchPathState];

        if (file == nil) {
            NSLog(@"Warning: Unable to read file: %@", adjustedName);
        } else {
            // as a side-effect, this call can add items to _machOFilesByName
            NSError *error = nil;
            BOOL loadedSuccessfully = [self loadFile:file error:&error depth:depth];

            // if recursive processing fails, it is possible to have loaded a library in the
            // loadFile:error:depth: call, but not its dependencies, producing an error above
            machOFile = _machOFilesByName[adjustedName];
            if (machOFile == nil) {
                NSLog(@"Warning: Couldn't load MachOFile with ID: %@, adjustedID: %@",
                        name,
                        adjustedName);
            } else if (!loadedSuccessfully) {
                NSLog(@"Warning: Loaded library, but not its dependencies: %@", adjustedName);
            }

            if (error) {
                NSLog(@"Warning:   %@", [error localizedDescription]);
            }
        }
    }

    return machOFile;
}

- (void)appendHeaderToString:(NSMutableString *)resultString;
{
    [resultString appendString:@"//\n"];
    [resultString appendFormat:@"//     Generated by PreEmptive Solutions for iOS - Rename version %s\n", CLASS_DUMP_VERSION];
    [resultString appendString:@"//\n\n"];

    if (self.sdkRoot != nil) {
        [resultString appendString:@"//\n"];
        [resultString appendFormat:@"// SDK Root: %@\n", self.sdkRoot];
        [resultString appendFormat:@"// Headers Root: %@\n", self.headersRoot];
        [resultString appendString:@"//\n\n"];
    }
}

- (void)registerTypes;
{
    for (CDObjectiveCProcessor *processor in self.objcProcessors) {
        [processor registerTypesWithObject:self.typeController phase:0];
    }
    [self.typeController endPhase:0];

    [self.typeController workSomeMagic];
}

- (void)showHeader;
{
    if ([self.machOFiles count] > 0) {
        [[[self.machOFiles lastObject] headerString:YES] print];
    }
}

- (void)showLoadCommands;
{
    if ([self.machOFiles count] > 0) {
        [[[self.machOFiles lastObject] loadCommandString:YES] print];
    }
}

- (int)obfuscateSourcesUsingMap:(NSString *)symbolsPath
              symbolsHeaderFile:(NSString *)symbolsHeaderFile
               workingDirectory:(NSString *)workingDirectory
                   xibDirectory:(NSString *)xibDirectory
{
    NSData *symbolsData = [NSData dataWithContentsOfFile:symbolsPath];
    if (symbolsData == nil) {
        NSLog(@"Error: Could not read from: %@", symbolsPath);
        return 1;
    }

    NSError *error = nil;
    NSDictionary *invertedSymbols = [NSJSONSerialization JSONObjectWithData:symbolsData
                                                                     options:0
                                                                       error:&error];
    if (invertedSymbols == nil) {
        NSLog(@"Warning: Could not load symbols data from: %@", symbolsPath);
        return 1;
    }

    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    for (NSString *key in invertedSymbols.allKeys) {
        symbols[invertedSymbols[key]] = key;
    }
    
    // write out the header file
    if (symbolsHeaderFile == nil) {
        symbolsHeaderFile = [workingDirectory stringByAppendingString:@"/symbols.h"];
    }
    symbolsHeaderFile = [symbolsHeaderFile absolutePath];

    [CDSymbolsGeneratorVisitor writeSymbols:symbols symbolsHeaderFile:symbolsHeaderFile];
    
    // Alter the Prefix.pch file or files to include the symbols header file
    int result = [self alterPrefixPCHFilesIn:workingDirectory injectingImportFor:symbolsHeaderFile];
    if (result != 0) {
        return result;
    }
    
    // apply renaming to the xib and storyboard files
    CDXibStoryBoardProcessor *processor = [CDXibStoryBoardProcessor new];
    processor.xibBaseDirectory = xibDirectory;
    [processor obfuscateFilesUsingSymbols:symbols];
    
    return 0;
}

- (int)alterPrefixPCHFilesIn:(NSString *)prefixPCHDirectory
          injectingImportFor:(NSString *)symbolsHeaderFileName
{
    NSString *textToInsert
            = [NSString stringWithFormat:@"#include \"%@\"\n", symbolsHeaderFileName];

    NSFileManager *fileManager = [NSFileManager new];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:prefixPCHDirectory];

    BOOL foundPrefixPCH = FALSE;
    NSString *filename;
    while (true) {
        filename = [enumerator nextObject];
        if (filename == nil) {
            break;
        }

        if ([[filename lowercaseString] hasSuffix:@"-prefix.pch"]) {
            foundPrefixPCH = TRUE;
            NSLog(@"Injecting include for %@ into %@",
                    [symbolsHeaderFileName lastPathComponent],
                    filename);

            NSError *error;
            NSStringEncoding encoding;
            NSMutableString *fileContents
                    = [[NSMutableString alloc] initWithContentsOfFile:filename
                                                         usedEncoding:&encoding
                                                                error:&error];
            if (fileContents == nil) {
                NSLog(@"Error: could not read file %@", filename);
                return 1;
            }

            [fileContents insertString:textToInsert atIndex:0];

            BOOL result = [fileContents writeToFile:filename
                                         atomically:YES
                                           encoding:encoding
                                              error:&error];
            if (!result) {
                NSLog(@"Error: could not update file %@", filename);
                return 1;
            }
        }
    }

    if (!foundPrefixPCH) {
        NSLog(@"Error: could not find any *-Prefix.pch files under %@", prefixPCHDirectory);
        return 1;
    }

    return 0;
}

#pragma mark - dylibsHelper

-(NSString*)getFilePathForPPiOSBundle:(NSString*)dylibName {
    
    NSString *  dylibsPath = [[NSBundle mainBundle] pathForResource:@"ppiOSBundle" ofType:@"bundle"];
    if (dylibsPath) {
        NSBundle * ppiOSBundle =  [NSBundle bundleWithPath:dylibsPath];
        if (ppiOSBundle) {
           NSString * path = [[ppiOSBundle resourcePath] stringByAppendingPathComponent:dylibName];
            return path;
        }
    }
    return nil;
    
}

@end

