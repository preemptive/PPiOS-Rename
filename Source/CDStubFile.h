// Copyright 2016 PreEmptive Solutions, LLC

#import <Foundation/Foundation.h>
#import "CDFatFile.h"

@interface CDStubFile : CDFatFile
@property (readonly) NSDictionary<NSString *, NSObject *> * stubbedData;
@property (readonly) NSString * filename;
@property (nonatomic, readonly) NSString * importBaseName;

- (id)initWithData:(NSData *)data fromPath:(NSString *)filename;
- (CDMachOFile *)machOFileWithArch:(CDArch)cdarch;
@end