// Copyright 2016 PreEmptive Solutions, LLC

#import "CDStubFile.h"
#import "CDMachOFile.h"
#import <YAML-Framework/YAMLSerialization.h>

@interface MockMachOFile : CDMachOFile
@property (nonatomic, readonly) NSDictionary<NSString *, NSObject *> * stubbedData;
@property (readonly) NSString * filename;

- (id)initWithStubData:(NSDictionary<NSString *, NSObject *> *)data
           andFilename:(NSString *)filename;
@end

@implementation MockMachOFile
@synthesize filename = _filename;

- (id)initWithStubData:(NSDictionary<NSString *, NSObject *> *)data
           andFilename:(NSString *)filename
{
    _stubbedData = data;
    _filename = filename;
    return self;
}
@end

@implementation CDStubFile {
}
@synthesize filename = _filename;

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
    return self;
}

- (CDMachOFile *)machOFileWithArch:(CDArch)cdarch
{
    return [[MockMachOFile alloc] initWithStubData:_stubbedData andFilename:_filename];
}
@end