// -*- mode: ObjC -*-

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

    NSString * currentDirectory = [[NSFileManager new] currentDirectoryPath];
    NSString * filename = [NSString stringWithFormat:@"%@/%@", currentDirectory, self];
    filename = [filename stringByStandardizingPath];
    return filename;
}
@end

@interface CDClassDump ()
@end

#pragma mark -

@implementation CDClassDump
{
    CDSearchPathState *_searchPathState;

    BOOL _shouldProcessRecursively;
    BOOL _shouldSortClasses; // And categories, protocols
    BOOL _shouldSortClassesByInheritance; // And categories, protocols
    BOOL _shouldSortMethods;

    BOOL _shouldShowIvarOffsets;
    BOOL _shouldShowMethodAddresses;
    BOOL _shouldShowHeader;
    BOOL _shouldOnlyAnalyze;
    BOOL _shouldOnlyObfuscate;

    NSRegularExpression *_regularExpression;

    NSString *_sdkRoot;
    NSMutableArray *_machOFiles;
    NSMutableDictionary *_machOFilesByName;
    NSMutableArray *_objcProcessors;

    CDTypeController *_typeController;

    CDArch _targetArch;
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

        _shouldShowHeader = YES;

        _maxRecursiveDepth = INT_MAX;
        _shouldOnlyAnalyze = NO;
        _shouldOnlyObfuscate = NO;
    }

    return self;
}

#pragma mark - Regular expression handling

- (BOOL)shouldShowName:(NSString *)name;
{
    if (self.regularExpression != nil) {
        NSTextCheckingResult *firstMatch = [self.regularExpression firstMatchInString:name options:(NSMatchingOptions)0 range:NSMakeRange(0, [name length])];
        return firstMatch != nil;
    }

    return YES;
}

#pragma mark -

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
    CDMachOFile *machOFile = [file machOFileWithArch:_targetArch];
    if (machOFile == nil) {
        if (error != NULL) {
            NSString *failureReason;
            NSString *targetArchName = CDNameForCPUType(_targetArch.cputype, _targetArch.cpusubtype);
            if ([file isKindOfClass:[CDFatFile class]] && [(CDFatFile *)file containsArchitecture:_targetArch]) {
                failureReason = [NSString stringWithFormat:@"Fat file doesn't contain a valid Mach-O file for the specified architecture (%@).  "
                                                            "It probably means that class-dump was run on a static library, which is not supported.", targetArchName];
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

    BOOL shouldProcessRecursively = [self shouldProcessRecursively] && depth < _maxRecursiveDepth;
    if(!shouldProcessRecursively && [self.forceRecursiveAnalyze containsObject:machOFile.importBaseName]) {
        shouldProcessRecursively = YES;
        NSLog(@"Forced recursively processing of %@", machOFile.importBaseName);
    }

    if (shouldProcessRecursively) {
        @try {
            for (CDLoadCommand *loadCommand in [machOFile loadCommands]) {
                if ([loadCommand isKindOfClass:[CDLCDylib class]]) {
                    CDLCDylib *dylibCommand = (CDLCDylib *)loadCommand;
                    if ([dylibCommand cmd] == LC_LOAD_DYLIB) {
                        [self.searchPathState pushSearchPaths:[machOFile runPaths]];
                        {
                            NSString *loaderPathPrefix = @"@loader_path";

                            NSString *path = [dylibCommand path];
                            if ([path hasPrefix:loaderPathPrefix]) {
                                NSString *loaderPath = [machOFile.filename stringByDeletingLastPathComponent];
                                path = [[path stringByReplacingOccurrencesOfString:loaderPathPrefix withString:loaderPath] stringByStandardizingPath];
                            }
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

- (void)processObjectiveCData;
{
    for (CDMachOFile *machOFile in self.machOFiles) {
        CDObjectiveCProcessor *processor = [[[machOFile processorClass] alloc] initWithMachOFile:machOFile];
        [processor process];
        [_objcProcessors addObject:processor];
    }
}

// This visits everything segment processors, classes, categories.  It skips over modules.  Need something to visit modules so we can generate separate headers.
- (void)recursivelyVisit:(CDVisitor *)visitor;
{
    [visitor willBeginVisiting];

    NSEnumerator *objcProcessors;
    if(self.shouldIterateInReverse) {
        objcProcessors = [self.objcProcessors reverseObjectEnumerator];
    } else {
        objcProcessors = [self.objcProcessors objectEnumerator];
    }

    for (CDObjectiveCProcessor *processor in objcProcessors) {
        [processor recursivelyVisit:visitor];
    }

    [visitor didEndVisiting];
}

- (CDMachOFile *)machOFileWithName:(NSString *)name andDepth:(int)depth {
    NSString *adjustedName = nil;
    NSString *executablePathPrefix = @"@executable_path";
    NSString *rpathPrefix = @"@rpath";

    NSFileManager * fileManager = [NSFileManager defaultManager];

    if ([name hasPrefix:executablePathPrefix]) {
        adjustedName = [name stringByReplacingOccurrencesOfString:executablePathPrefix
                                                       withString:self.searchPathState.executablePath];
    } else if ([name hasPrefix:rpathPrefix]) {
        for (NSString * searchPath in [self.searchPathState searchPaths]) {
            NSString * str = [name stringByReplacingOccurrencesOfString:rpathPrefix
                                                             withString:searchPath];
            if ([fileManager fileExistsAtPath:str]) {
                adjustedName = str;
                break;
            }
        }

        if (adjustedName == nil) {
            adjustedName = name;
        }
    } else if (self.sdkRoot != nil) {
        adjustedName = [self.sdkRoot stringByAppendingPathComponent:name];
    } else {
        adjustedName = name;
    }

    BOOL fileIsStub = NO;
    if (![fileManager fileExistsAtPath:adjustedName]) {
        NSString * stubFile = adjustedName;
        if ([adjustedName hasSuffix:@".dylib"]) {
            stubFile = [stubFile stringByDeletingPathExtension];
        }
        stubFile = [stubFile stringByAppendingPathExtension:@"tbd"];

        if ([fileManager fileExistsAtPath:stubFile]) {
            fileIsStub = YES;
            adjustedName = stubFile;
        }
    }

    CDMachOFile *machOFile = _machOFilesByName[adjustedName];
    if (machOFile == nil) {
        CDFile * file = [CDFile fileWithContentsOfFile:adjustedName
                                       searchPathState:self.searchPathState
                                           isAStubFile:fileIsStub];

        if (file == nil) {
            NSLog(@"Warning: Unable to read file: %@", adjustedName);
        } else {
            // as a side-effect, this call can add items to _machOFilesByName
            NSError * error = nil;
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
    // Since this changes each version, for regression testing it'll be better to be able to not show it.
    if (self.shouldShowHeader == NO)
        return;

    [resultString appendString:@"//\n"];
    [resultString appendFormat:@"//     Generated by PreEmptive Solutions for iOS - Class Guard version %s\n", CLASS_DUMP_VERSION];
    [resultString appendString:@"//\n\n"];

    if (self.sdkRoot != nil) {
        [resultString appendString:@"//\n"];
        [resultString appendFormat:@"// SDK Root: %@\n", self.sdkRoot];
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
    NSData * symbolsData = [NSData dataWithContentsOfFile:symbolsPath];
    if (symbolsData == nil) {
        NSLog(@"Error: Could not read from: %@", symbolsPath);
        return 1;
    }

    NSError * error = nil;
    NSDictionary * invertedSymbols = [NSJSONSerialization JSONObjectWithData:symbolsData
                                                                     options:0
                                                                       error:&error];
    if (invertedSymbols == nil) {
        NSLog(@"Warning: Could not load symbols data from: %@", symbolsPath);
        return 1;
    }

    NSMutableDictionary * symbols = [NSMutableDictionary dictionary];
    for (NSString * key in invertedSymbols.allKeys) {
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
    CDXibStoryBoardProcessor * processor = [CDXibStoryBoardProcessor new];
    processor.xibBaseDirectory = xibDirectory;
    [processor obfuscateFilesUsingSymbols:symbols];
    
    return 0;
}

- (int)alterPrefixPCHFilesIn:(NSString *)prefixPCHDirectory
          injectingImportFor:(NSString *)symbolsHeaderFileName
{
    NSString * textToInsert
            = [NSString stringWithFormat:@"#import \"%@\"\n", symbolsHeaderFileName];

    NSFileManager * fileManager = [NSFileManager new];
    NSDirectoryEnumerator * enumerator = [fileManager enumeratorAtPath:prefixPCHDirectory];

    BOOL foundPrefixPCH = FALSE;
    NSString * filename;
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

            NSError * error;
            NSStringEncoding encoding;
            NSMutableString * fileContents
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

@end

