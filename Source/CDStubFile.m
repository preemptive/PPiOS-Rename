// Copyright 2016 PreEmptive Solutions, LLC

#import "CDStubFile.h"
#import "CDMachOFile.h"
#import "CDObjectiveCProcessor.h"
#import "CDOCClass.h"
#import <YAML-Framework/YAMLSerialization.h>

@interface StubSingleArchMachOFile : CDMachOFile
@property (nonatomic, readonly) NSDictionary<NSString *, NSObject *> * stubbedData;
@property (readonly) NSString * filename;
@property (nonatomic, readonly) NSString * importBaseName;

- (id)initWithStubData:(NSDictionary<NSString *, NSObject *> *)data
           andFilename:(NSString *)filename
       usingImportName:(NSString *)importName;
- (Class)processorClass;
@end


@interface StubObjectiveCProcessor : CDObjectiveCProcessor
@property (readonly) StubSingleArchMachOFile * machOFile;
- (id)initWithMachOFile:(CDMachOFile *)machOFile;
@end


@implementation CDStubFile
@synthesize filename = _filename;
@synthesize importBaseName = _importBaseName;

- (id)initWithData:(NSData *)data
          fromPath:(NSString *)filename {
    _filename = filename;

    NSInputStream * stream = [[NSInputStream alloc] initWithData:data];
    NSError * error = nil;
    id object = [YAMLSerialization objectWithYAMLStream:stream
                                                options:kYAMLReadOptionStringScalars
                                                  error:&error];

    //NSLog(@"Info: %@", [object description]);
//    if (![object isKindOfClass:[NSDictionary class]]) {
//        NSLog(@"Error: Unable to read stub file %@", path);
//        return nil;
//    }

    _stubbedData = (NSDictionary<NSString *, NSObject *> *)object;
    _importBaseName = (NSString *)_stubbedData[@"install-name"];
    return self;
}

- (CDMachOFile *)machOFileWithArch:(CDArch)cdarch
{
    return [[StubSingleArchMachOFile alloc] initWithStubData:_stubbedData
                                                 andFilename:_filename
                                             usingImportName:_importBaseName];
}
@end


@implementation StubSingleArchMachOFile
@synthesize filename = _filename;
@synthesize importBaseName = _importBaseName;

- (id)initWithStubData:(NSDictionary<NSString *, NSObject *> *)data
           andFilename:(NSString *)filename
       usingImportName:(NSString *)importName
{
    _stubbedData = data;
    _filename = filename;
    _importBaseName = importName;
    return self;
}

- (Class)processorClass {
    return [StubObjectiveCProcessor class];
}
@end


@implementation StubObjectiveCProcessor
@synthesize machOFile = _machOFile;

- (id)initWithMachOFile:(CDMachOFile *)machOFile
{
    if (![machOFile isKindOfClass:[StubSingleArchMachOFile class]]) {
        // TODO: add a warning/error here?
        return nil;
    }

    self = [super initWithMachOFile:machOFile];
    if (!self) {
        return self;
    }

    _machOFile = (StubSingleArchMachOFile *)machOFile;

    StubSingleArchMachOFile * singleArch = (StubSingleArchMachOFile *)machOFile;
    NSArray * exports = (NSArray *)[singleArch stubbedData][@"exports"];

//int index = 0;

    for (NSDictionary<NSString *, NSArray *> * segment in exports) {
        NSArray<NSString *> * listOfClasses = segment[@"objc-classes"];

        for (NSString * className in listOfClasses) {
            CDOCClass * stubClass = [CDOCClass new]; // may need to use alloc+custom init
            stubClass.name = className;
            u_int32_t randomAddress = arc4random_uniform(0xFFFFFFFF); // TODO: find the right constant for this
            [self addClass:stubClass withAddress:randomAddress];
        }

// TODO: remove the following debugging code
//        for (NSString * section in segment.allKeys) {
//            NSLog(@"file %@ segment %d section %@", singleArch.filename, index, section);
//        }
//            NSArray<NSString *> * list = segment[@"re-exports"];
//            for (NSString * symbol in list) {
//                NSLog(@"file %@ segment %d variety re-export symbol %@", singleArch.filename, index, symbol);
//            }
//        for (NSString * variety in @[@"objc-classes", @"objc-ivars", @"symbols"]) {
//            NSArray<NSString *> * list = segment[variety];
//            for (NSString * symbol in list) {
//                NSLog(@"segment %d variety %@ symbol %@", index, variety, symbol);
//            }
//        }
//        index++;
    }

    return self;
}
@end
