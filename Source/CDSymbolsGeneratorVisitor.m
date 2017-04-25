/********************************************
  Copyright 2016-2017 PreEmptive Solutions, LLC
  See LICENSE.txt for licensing information
********************************************/
  
#import "CDSymbolsGeneratorVisitor.h"
#import "CDOCProtocol.h"
#import "CDOCClass.h"
#import "CDOCCategory.h"
#import "CDOCMethod.h"
#import "CDVisitorPropertyState.h"
#import "CDOCInstanceVariable.h"
#import "CDOCProperty.h"
#import "CDObjectiveCProcessor.h"
#import "CDMachOFile.h"
#import "CDType.h"

#define DOUBLE_GUARD_NAME "DOUBLE_OBFUSCATION_GUARD_PPIOS"

static const int maxLettersSet = 3;
static NSString *const lettersSet[maxLettersSet] = {
        @"abcdefghijklmnopqrstuvwxyz",
        @"0123456789",
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
};

@implementation CDSymbolsGeneratorVisitor {
    NSMutableSet *_protocolNames;
    NSMutableSet *_classNames;
    NSMutableSet *_categoryNames;
    NSMutableSet *_propertyNames;
    NSMutableSet *_methodNames;
    NSMutableSet *_ivarNames;
    NSMutableSet *_forbiddenNames;

    NSMutableDictionary *_symbols;
    NSMutableSet *_uniqueSymbols;

    NSInteger _symbolLength;
    BOOL _external;
    BOOL _ignored;
    NSString *_guardName;
}

- (void)addKnownForbiddenSymbols {
    // More important than this list itself, is deciding on the right process to produce this list.
    // Items have been added to this list manually which should perhaps be found automatically, but
    // determining this is an aspect of refining the process to produce this list.
    [_forbiddenNames addObjectsFromArray:@[
            @"BOOL", // objc typedef, objc.h
            @"Class", // objc typedef, objc.h
            @"IMP", // objc typedef, objc.h
            @"NO", // objc define, objc.h
            @"NULL", // c define, _null.h
            @"SEL", // objc typedef, objc.h
            @"YES", // objc define, objc.h
            @"_Bool", // historical
            @"_cmd", // historical
            @"_inline", // historical
            @"assign", // objc keyword, properties
            @"atomic", // objc keyword, properties
            @"auto", // c keyword
            @"autoreleasepool", // objc @ keyword
            @"bool", // c define, stdbool.h
            @"break", // c keyword
            @"bycopy", // objc keyword
            @"byref", // objc keyword
            @"case", // c keyword
            @"catch", // objc @ keyword
            @"char", // c keyword
            @"class", // objc @ keyword
            @"compatibility_alias", // objc @ keyword
            @"const", // c keyword
            @"continue", // c keyword
            @"default", // c keyword
            @"do", // c keyword
            @"double", // c keyword
            @"dynamic", // objc @ keyword
            @"else", // c keyword
            @"encode", // objc @ keyword
            @"end", // objc @ keyword
            @"enum", // c keyword
            @"extern", // c keyword
            @"false", // c define, stdbool.h
            @"finally", // objc @ keyword
            @"float", // c keyword
            @"for", // c keyword
            @"getter", // objc keyword, properties
            @"goto", // c keyword
            @"id", // objc typedef, objc.h
            @"if", // c keyword
            @"implementation", // objc @ keyword
            @"import", // objc @ keyword
            @"in", // objc keyword
            @"inline", // c keyword
            @"inout", // objc keyword
            @"instancetype", // objc keyword
            @"int", // c keyword
            @"interface", // objc @ keyword
            @"isa", // objc struct member, objc.h, deprecated but still accessible
            @"long", // c keyword
            @"nil", // objc keyword
            @"nonatomic", // objc keyword, properties
            @"nullable", // objc keyword
            @"objc_object", // objc struct, objc.h
            @"objc_selector", // objc struct, objc.h
            @"oneway", // objc keyword
            @"optional", // objc @ keyword
            @"out", // objc keyword
            @"package", // objc @ keyword
            @"private", // objc @ keyword
            @"property", // objc @ keyword
            @"protected", // objc @ keyword
            @"protocol", // objc @ keyword
            @"public", // objc @ keyword
            @"readonly", // objc keyword, properties
            @"readwrite", // objc keyword, properties
            @"register", // c keyword
            @"required", // objc @ keyword
            @"restrict", // c keyword
            @"retain", // objc keyword, properties
            @"return", // c keyword
            @"selector", // objc @ keyword
            @"self", // objc keyword
            @"setter", // objc keyword, properties
            @"short", // c keyword
            @"signed", // c keyword
            @"sizeof", // c keyword
            @"static", // c keyword
            @"strong", // objc keyword, properties
            @"struct", // c keyword
            @"super", // objc keyword
            @"switch", // c keyword
            @"synchronized", // objc @ keyword
            @"synthesize", // objc @ keyword
            @"throw", // objc @ keyword
            @"true", // c define, stdbool.h
            @"try", // objc @ keyword
            @"typedef", // c keyword
            @"typeof", // c keyword
            @"union", // c keyword
            @"unsafe_unretained", // objc keyword, properties
            @"unsigned", // c keyword
            @"void", // c keyword
            @"volatile", // c keyword
            @"weak", // objc keyword, properties
            @"while", // c keyword
    ]];
}

- (void)willBeginVisiting {
    _protocolNames = [NSMutableSet new];
    _classNames = [NSMutableSet new];
    _categoryNames = [NSMutableSet new];
    _propertyNames = [NSMutableSet new];
    _methodNames = [NSMutableSet new];
    _ivarNames = [NSMutableSet new];
    _symbols = [NSMutableDictionary new];
    _uniqueSymbols = [NSMutableSet new];
    _forbiddenNames = [NSMutableSet new];
    _symbolLength = 3;
    _external = NO;
    _ignored = NO;
    _guardName = nil;
    [self addKnownForbiddenSymbols];
}

- (void)didEndVisiting {
    NSLog(@"Generating symbol table...");
    NSLog(@"Protocols = %ld", _protocolNames.count);
    NSLog(@"Classes = %ld", _classNames.count);
    NSLog(@"Categories = %ld", _categoryNames.count);
    NSLog(@"Methods = %ld", _methodNames.count);
    NSLog(@"I-vars = %ld", _ivarNames.count);
    NSLog(@"Filters = %ld", _classFilters.count);
    NSLog(@"Ignore symbol patterns = %ld", _exclusionPatterns.count);
    NSLog(@"Forbidden keywords = %ld", _forbiddenNames.count);

    [self writeExcludesIfRequested];

    NSArray *propertyNames = [_propertyNames.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *n1, NSString *n2) {
        if (n1.length > n2.length)
            return NSOrderedDescending;
        if (n1.length < n2.length)
            return NSOrderedAscending;
        return NSOrderedSame;
    }];

    for (NSString *propertyName in propertyNames) {
        [self generatePropertySymbols:propertyName];
    }

    for (NSString *protocolName in _protocolNames) {
        [self generateSimpleSymbols:protocolName];
    }

    for (NSString *className in _classNames) {
        [self generateSimpleSymbols:className];
    }

    for (NSString *categoryName in _categoryNames) {
        [self generateSimpleSymbols:categoryName];
    }

    for (NSString *methodName in _methodNames) {
        [self generateMethodSymbols:methodName];
    }

    for (NSString *ivarName in _ivarNames) {
        [self generateSimpleSymbols:ivarName];
    }

    NSLog(@"Done generating symbol table.");
    NSLog(@"Generated unique symbols (_uniqueSymbols.count) = %ld", _uniqueSymbols.count);
    NSLog(@"Generated unique symbols ([_symbols count]) = %ld", [_symbols count]);
}

- (void)writeExcludesIfRequested {
    if (!_diagnosticFilesPrefix) {
        return;
    }

    [self writeListToFile:@"-classFilters.list" theList:_classFilters];
    [self writeListToFile:@"-exclusionPatterns.list" theList:_exclusionPatterns];
    [self writeSetToFile:@"-forbiddenNames.list" theSet:_forbiddenNames];
}

- (void)writeListToFile:(NSString *)suffix theList:(NSArray<NSString *> *)list {

    NSString *filename = [_diagnosticFilesPrefix stringByAppendingString:suffix];

    NSMutableString *stringBuilder = [NSMutableString new];
    for (NSString *symbol in list) {
        [stringBuilder appendFormat:@"%@\n", symbol];
    }

    NSError *error = nil;
    [stringBuilder writeToFile:filename
                    atomically:TRUE
                      encoding:NSUTF8StringEncoding
                         error:&error];

    if (error) {
        NSLog(@"ppios-rename: error: unable to write list: %@ reason: %@",
                filename,
                [error localizedFailureReason]);
        exit(1);
    }
}

- (void)writeSetToFile:(NSString *)suffix theSet:(NSSet<NSString *> *)set {

    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithArray:[set allObjects]];
    [list sortUsingSelector:@selector(compare:)];

    [self writeListToFile:suffix theList:list];
}

+ (void)appendDefineTo:(NSMutableString *)stringBuilder
              renaming:(NSString *)oldName
                    to:(NSString *)newName {
    [stringBuilder appendFormat:@"#ifndef %@\n", oldName];
    [stringBuilder appendFormat:@"#define %@ %@\n", oldName, newName];
    [stringBuilder appendFormat:@"#endif // %@\n", oldName];
}

+ (void)writeSymbols:(NSDictionary<NSString *, NSString *> *)symbols
   symbolsHeaderFile:(NSString *)symbolsHeaderFile {

    NSLog(@"Writing symbols file %ld ...", symbols.count);
    NSMutableString *stringBuilder = [NSMutableString new];

    // add guard to include the content of the file once
    [stringBuilder appendString:@"/* generated by PreEmptive Protection for iOS - Class Guard */\n"];
    [stringBuilder appendString:@"\n"];
    [stringBuilder appendString:@"#ifndef "DOUBLE_GUARD_NAME"\n"];
    [stringBuilder appendString:@"#define "DOUBLE_GUARD_NAME"\n"];
    [stringBuilder appendString:@"#else\n"];
    [stringBuilder appendString:@"#error Double obfuscation detected. This will result in an unobfuscated binary. Please see the documentation for details.\n"];
    [stringBuilder appendString:@"#endif\n"];

    [symbols enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [self appendDefineTo:stringBuilder renaming:key to:value];
    }];

    NSData *data = [stringBuilder dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:symbolsHeaderFile atomically:YES];

    NSLog(@"Done writing symbols file.");
}

- (BOOL)checkForExistingSymbols:(NSSet*) symbols {
    for(NSMutableSet* nameSet in @[_propertyNames, _protocolNames, _classNames, _categoryNames, _methodNames, _ivarNames]){
        for(NSString* symbol in symbols){
            if ([nameSet containsObject:symbol]) {
                return true;
            }
        }
    }
    return false;
}

- (NSString *)generateRandomStringWithPrefix:(NSString *)prefix  andName:(NSString *)originalName{
    if(_guardName == nil ) {
        //fairly expensive to check over everything, so only do this once
        NSString *guard = @"X__PPIOS_DOUBLE_OBFUSCATION_GUARD__";
        //exclude all symbols in case what was obfuscated was a property
        NSSet* symbols = [NSSet setWithObjects:guard, [@"_" stringByAppendingString:guard], [@"set" stringByAppendingString:guard], nil];

        if([self checkForExistingSymbols:symbols]) {
            //contains guard string.. (in case it's a name like setGuardName.. )
            fprintf(stderr, "Error: Analyzing an already obfuscated binary. This will result in an unobfuscated binary. Please see the documentation for details.\n");
            exit(9);
        }
        _guardName = originalName;
        return guard;
    }
    if([originalName isEqualToString:_guardName]){
        //For some reason obfuscating the same name again..
        //Maybe there is a conflict in a property, so generate a new name and let the guard be inserted later
        _guardName = nil;
    }
    NSInteger length = 8;
    while (true) {
        NSMutableString *randomString = [NSMutableString stringWithCapacity:length];
        if (prefix) {
            [randomString appendString:prefix];
        }

        for (int i = 0; i < length; i++) {
            NSString *letters = lettersSet[MIN(i, maxLettersSet - 1)];
            NSInteger index = arc4random_uniform((u_int32_t) letters.length);
            [randomString appendString:[letters substringWithRange:NSMakeRange(index, 1)]];
        }

        if ([_uniqueSymbols containsObject:randomString]) {
            ++length;
            continue;
        }

        return randomString;
    }
}

- (NSString *)generateRandomString:(NSString *)originalName{
    return [self generateRandomStringWithPrefix:nil andName:originalName];
}

- (BOOL)doesContainGeneratedSymbol:(NSString *)symbol {
    return _symbols[symbol] != nil;
}

- (void)generateSimpleSymbols:(NSString *)symbolName {
    NSLog(@"generate for generateSimpleSymbols: %@", symbolName);
    if ([self doesContainGeneratedSymbol:symbolName]) {
        return;
    }
    if ([self shouldSymbolsBeIgnored:symbolName]) {
        return;
    }
    NSString *newSymbolName = [self generateRandomString:symbolName];
    [self addGenerated:newSymbolName forSymbol:symbolName];
}

- (bool)isInitMethod:(NSString *)symbolName {
    if (![symbolName hasPrefix:@"init"]) {
        return NO;
    }

    // just "init"
    if (symbolName.length == 4) {
        return YES;
    }

    // we expect that next character after init is in UPPER CASE
    return isupper([symbolName characterAtIndex:4]) != 0;

}

- (NSString *)getterNameForMethodName:(NSString *)methodName {
    NSString *setterPrefix = @"set";
    BOOL hasSetterPrefix = [methodName hasPrefix:setterPrefix];
    BOOL isEqualToSetter = [methodName isEqualToString:setterPrefix];

    if (hasSetterPrefix && !isEqualToSetter) {
        BOOL isFirstLetterAfterPrefixUppercase = [[methodName substringFromIndex:setterPrefix.length] isFirstLetterUppercase];

        NSString *methodNameToObfuscate = methodName;

        // exclude method names like setupSomething
        if (isFirstLetterAfterPrefixUppercase) {
            methodNameToObfuscate = [methodName stringByReplacingCharactersInRange:NSMakeRange(0, setterPrefix.length) withString:@""];
        }

        if (![self shouldSymbolStartWithLowercase:methodNameToObfuscate]) {
            return methodNameToObfuscate;
        } else {
            return [methodNameToObfuscate lowercaseFirstCharacter];
        }
    } else {
        return methodName;
    }
}

- (BOOL)shouldSymbolStartWithLowercase:(NSString *)symbol {
    // if two first characters in symbol are uppercase name should not be changed to lowercase
    if (symbol.length > 1) {
        NSString *prefix = [symbol substringToIndex:2];
        if ([prefix isEqualToString:[prefix uppercaseString]]) {
            return NO;
        }
    } else if ([symbol isEqualToString:[symbol uppercaseString]]) {
        return NO;
    }
    return YES;
}

- (NSString *)setterNameForMethodName:(NSString *)methodName {
    NSString *setterPrefix = @"set";
    BOOL hasSetterPrefix = [methodName hasPrefix:setterPrefix];
    BOOL isEqualToSetter = [methodName isEqualToString:setterPrefix];

    if (hasSetterPrefix && !isEqualToSetter) {
        BOOL isFirstLetterAfterPrefixUppercase = [[methodName substringFromIndex:setterPrefix.length] isFirstLetterUppercase];
        // Excludes methods like setupSomething
        if (isFirstLetterAfterPrefixUppercase) {
            return methodName;
        } else {
            return [setterPrefix stringByAppendingString:[methodName capitalizeFirstCharacter]];
        }
    } else {
        return [setterPrefix stringByAppendingString:[methodName capitalizeFirstCharacter]];
    }
}

- (void)generateMethodSymbols:(NSString *)symbolName {
    NSLog(@"generate for generateMethodSymbols: %@", symbolName);
    NSString *getterName = [self getterNameForMethodName:symbolName];
    NSString *setterName = [self setterNameForMethodName:symbolName];

    if ([self doesContainGeneratedSymbol:getterName] && [self doesContainGeneratedSymbol:setterName]) {
        return;
    }
    if ([self shouldSymbolsBeIgnored:getterName] || [self shouldSymbolsBeIgnored:setterName]) {
        return;
    }
    if ([self isInitMethod:symbolName]) {
        NSString *initPrefix = @"initL";
        NSString *newSymbolName = [self generateRandomStringWithPrefix:initPrefix andName:symbolName];
        [self addGenerated:newSymbolName forSymbol:symbolName];
    } else {
        NSString *newSymbolName = [self generateRandomString:symbolName];
        [self addGenerated:newSymbolName forSymbol:getterName];
        // Why is this being added?
        [self addGenerated:[@"set" stringByAppendingString:[newSymbolName capitalizeFirstCharacter]] forSymbol:setterName];
    }
}

- (NSString *)plainIvarPropertyName:(NSString *)propertyName {
    return [@"_" stringByAppendingString:[self plainGetterName:propertyName]];
}

- (NSString *)isIvarPropertyName:(NSString *)propertyName {
    return [@"_" stringByAppendingString:[self isGetterName:propertyName]];
}

- (NSString *)plainGetterName:(NSString *)propertyName {
    if ([propertyName hasPrefix:@"is"] && ![propertyName isEqualToString:@"is"]) {
        NSString *string = [propertyName stringByReplacingCharactersInRange:NSMakeRange(0, 2) withString:@""];
        // If property name is all upper case then don't change first letter to lower case e.g. URL should remain URL, not uRL
        if (![self shouldSymbolStartWithLowercase:string]) {
            return string;
        } else {
            return [string lowercaseFirstCharacter];
        }
    } else if (![self shouldSymbolStartWithLowercase:propertyName]){
        return propertyName;
    } else {
        return [propertyName lowercaseFirstCharacter];
    }
}

- (NSString *)isGetterName:(NSString *)propertyName {
    if ([propertyName hasPrefix:@"is"] && ![propertyName isEqualToString:@"is"]) {
        return propertyName;
    } else {
        return [@"is" stringByAppendingString:[propertyName capitalizeFirstCharacter]];
    }
}

- (NSString *)plainSetterPropertyName:(NSString *)propertyName {
    return [@"set" stringByAppendingString:[[self plainGetterName:propertyName] capitalizeFirstCharacter]];
}

- (NSString *)isSetterPropertyName:(NSString *)propertyName {
    return [@"set" stringByAppendingString:[[self isGetterName:propertyName] capitalizeFirstCharacter]];
}

- (void)addGenerated:(NSString *)generatedSymbol forSymbol:(NSString *)symbol {
    if (_symbols[symbol] != nil) {
        NSLog(@"(duplicate)");
    }

    [_uniqueSymbols addObject:generatedSymbol];
    _symbols[symbol] = generatedSymbol;

    NSLog(@"from %@ to %@ (%ld, %ld)", symbol, generatedSymbol, _uniqueSymbols.count, [_symbols count]);
}

- (void)generatePropertySymbols:(NSString *)propertyName {
    NSLog(@"generate for generatePropertySymbols: %@", propertyName);

    NSArray *symbols = [self symbolsForProperty:propertyName];
    BOOL shouldSymbolBeIgnored = NO;
    for (NSString *symbolName in symbols) {
        if ([self shouldSymbolsBeIgnored:symbolName]) {
            shouldSymbolBeIgnored = YES;
            break;
        }
    }

    // don't generate symbol if any of the name is forbidden
    if (shouldSymbolBeIgnored) {
        for (NSString *symbol in symbols) {
            [self addForbiddenSymbol:symbol];
        }
        return;
    }

    NSString *newPropertyName = _symbols[propertyName];

    // reuse previously generated symbol
    if (newPropertyName) {
        NSDictionary *symbolMapping = [self symbolMappingForOriginalPropertyName:propertyName generatedPropertyName:newPropertyName];
        for (NSString *key in symbolMapping.allKeys) {
            [self addGenerated:symbolMapping[key] forSymbol:key];
        }
        return;
    }

    [self createNewSymbolsForProperty:propertyName];

}

- (void)addForbiddenSymbol:(NSString *)symbol {
    [_forbiddenNames addObject:symbol];
}

- (void)createNewSymbolsForProperty:(NSString *)propertyName {
    NSLog(@"generate for createNewSymbolsForProperty: %@", propertyName);
    NSInteger symbolLength = propertyName.length;

    while (true) {
        NSString *newPropertyName = [self generateRandomStringWithPrefix:nil andName:propertyName];
        NSArray *symbols = [self symbolsForProperty:newPropertyName];

        BOOL isAlreadyGenerated = NO;
        for (NSString *symbolName in symbols) {
            if ([_uniqueSymbols containsObject:symbolName]) {
                isAlreadyGenerated = YES;
                break;
            }
        }
        // check if symbol is already generated
        if (!isAlreadyGenerated) {
            NSDictionary *symbolMapping = [self symbolMappingForOriginalPropertyName:propertyName generatedPropertyName:newPropertyName];
            for (NSString *key in symbolMapping.allKeys) {
                [self addGenerated:symbolMapping[key] forSymbol:key];
            }
            return;
        }

        ++symbolLength;
    }
}

- (NSDictionary *)symbolMappingForOriginalPropertyName:(NSString *)originalPropertyName generatedPropertyName:(NSString *)generatedName {
    NSString *ivarName = [self plainIvarPropertyName:originalPropertyName];
    NSString *isIvarName = [self isIvarPropertyName:originalPropertyName];
    NSString *getterName = [self plainGetterName:originalPropertyName];
    NSString *isGetterName = [self isGetterName:originalPropertyName];
    NSString *setterName = [self plainSetterPropertyName:originalPropertyName];
    NSString *isSetterName = [self isSetterPropertyName:originalPropertyName];

    NSString *newIvarName = [self plainIvarPropertyName:generatedName];
    NSString *newIsIvarName = [self isIvarPropertyName:generatedName];
    NSString *newGetterName = [self plainGetterName:generatedName];
    NSString *newIsGetterName = [self isGetterName:generatedName];
    NSString *newSetterName = [self plainSetterPropertyName:generatedName];
    NSString *newIsSetterName = [self isSetterPropertyName:generatedName];

    return @{ivarName : newIvarName,
            isIvarName : newIsIvarName,
            getterName : newGetterName,
            isGetterName : newIsGetterName,
            setterName : newSetterName,
            isSetterName : newIsSetterName};
}

- (NSArray *)symbolsForProperty:(NSString *)propertyName {
    NSString *ivarName = [self plainIvarPropertyName:propertyName];
    NSString *isIvarName = [self isIvarPropertyName:propertyName];
    NSString *getterName = [self plainGetterName:propertyName];
    NSString *isGetterName = [self isGetterName:propertyName];
    NSString *setterName = [self plainSetterPropertyName:propertyName];
    NSString *isSetterName = [self isSetterPropertyName:propertyName];

    NSMutableArray *symbols = [NSMutableArray arrayWithObject:ivarName];
    [symbols addObject:isIvarName];
    [symbols addObject:getterName];
    [symbols addObject:isGetterName];
    [symbols addObject:setterName];
    [symbols addObject:isSetterName];
    return symbols;
}

- (BOOL)shouldClassBeObfuscated:(NSString *)className {
    // Since this algorithm terminates when it first find a match, try matching from the most
    // specific to most general.
    for (NSString *filter in self.classFilters) {
        if ([filter hasPrefix:@"!"]) {
            // negative filter - prefixed with !
            if ([className isLike:[filter substringFromIndex:1]]) {
                return NO;
            }
        } else {
            // positive filter
            if ([className isLike:filter]) {
                return YES;
            }
        }
    }

    return YES;
}

- (BOOL)shouldSymbolsBeIgnored:(NSString *)symbolName {
    if ([_forbiddenNames containsObject:symbolName]) {
        return YES;
    }

    for (NSString *filter in self.exclusionPatterns) {
        if ([symbolName isLike:filter]) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - CDVisitor

- (void)willVisitObjectiveCProcessor:(CDObjectiveCProcessor *)processor {
    NSString *importBaseName = processor.machOFile.importBaseName;
    if (importBaseName) {
        if ([importBaseName isEqualTo:_frameworkName]) {
            NSLog(@"Processing internal symbols from %@...", importBaseName);
            _external = NO;
        } else  {
            NSLog(@"Processing external symbols from %@...", importBaseName);
            _external = YES;
        }
    } else {
        NSLog(@"Processing internal symbols...");
        _external = NO;
    }
}

- (void)willVisitProtocol:(CDOCProtocol *)protocol {
    if (_external) {
        [self addForbiddenSymbol:protocol.name];
        _ignored = YES;
    } else if (![self shouldClassBeObfuscated:protocol.name]) {
        NSLog(@"Ignoring @protocol %@", protocol.name);
        [self addForbiddenSymbol:protocol.name];
        _ignored = YES;
    } else {
        NSLog(@"Adding @protocol %@", protocol.name);
        [_protocolNames addObject:protocol.name];
        _ignored = NO;
    }
}

- (void)willVisitClass:(CDOCClass *)aClass {
    if (_external) {
        [self addForbiddenSymbol:aClass.name];

        if (![aClass.name hasSuffix:@"Delegate"] && ![aClass.name hasSuffix:@"Protocol"]) {
            [self addForbiddenSymbol:[aClass.name stringByAppendingString:@"Delegate"]];
            [self addForbiddenSymbol:[aClass.name stringByAppendingString:@"Protocol"]];
        }

        _ignored = YES;
    } else if (![self shouldClassBeObfuscated:aClass.name]) {
        NSLog(@"Ignoring @class %@", aClass.name);
        [self addForbiddenSymbol:aClass.name];
        _ignored = YES;
    } else {
        NSLog(@"Adding @class %@", aClass.name);
        [_classNames addObject:aClass.name];
        _ignored = NO;
    }
}

- (void)willVisitCategory:(CDOCCategory *)category {
    if (_external) {
        _ignored = YES;
    } else if (![self shouldClassBeObfuscated:category.name]) {
        NSLog(@"Ignoring @category %@+%@", category.className, category.name);
        [self addForbiddenSymbol:category.name];
        _ignored = YES;
    } else {
        NSLog(@"Adding @category %@+%@", category.className, category.name);
        [_categoryNames addObject:category.name];
        _ignored = NO;
    }
}

- (void)visitClassMethod:(CDOCMethod *)method {
    [self visitAndExplodeMethod:method.name];
}

- (void)visitAndExplodeMethod:(NSString *)method {
    for (NSString *component in [method componentsSeparatedByString:@":"]) {
        if ([component length]) {
            if (_ignored) {
                [self addForbiddenSymbol:component];
            } else {
                [_methodNames addObject:component];
            }
        }
    }
}

- (void)visitInstanceMethod:(CDOCMethod *)method propertyState:(CDVisitorPropertyState *)propertyState {
    [self visitAndExplodeMethod:method.name];

//    if (!_ignored && [method.name rangeOfString:@":"].location == NSNotFound) {
//        [_propertyNames addObject:method.name];
//    }
}

- (void)visitIvar:(CDOCInstanceVariable *)ivar {
    if (_ignored) {
        [self visitType:ivar.type];
    } else {
        [_ivarNames addObject:ivar.name];
    }
}

- (void)visitProperty:(CDOCProperty *)property {
    if (_ignored) {
        [self addForbiddenSymbol:property.name];
        [self addForbiddenSymbol:property.defaultGetter];
        [self addForbiddenSymbol:[@"_" stringByAppendingString:property.name]];
        [self addForbiddenSymbol:property.defaultSetter];
        [self visitType:property.type];
    } else {
        [_propertyNames addObject:property.name];
    }
}

- (void)visitRemainingProperties:(CDVisitorPropertyState *)propertyState {
    for (CDOCProperty *property in propertyState.remainingProperties) {
        [self visitProperty:property];
    }
}

- (void)visitType:(CDType *)type {
    // Exclusions should not propagate to ivars or properties for internal classes.
    if (_ignored && _external) {
        // Add protocols and the type name describing the type, these are exposed through
        // property_getAttributes() in objc/runtime.h.
        for (NSString *protocol in type.protocols) {
            [self addForbiddenSymbol:protocol];
        }

        if (type.typeName) {
            [self addForbiddenSymbol:[NSString stringWithFormat:@"%@", type.typeName]];
        }
    }
}

@end
