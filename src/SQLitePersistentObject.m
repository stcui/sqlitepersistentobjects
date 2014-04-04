
// ----------------------------------------------------------------------
// Part of the SQLite Persistent Objects for Cocoa and Cocoa Touch
//
// Original Version: (c) 2008 Jeff LaMarche (jeff_Lamarche@mac.com)
// ----------------------------------------------------------------------
// This code may be used without restriction in any software, commercial,
// free, or otherwise. There are no attribution requirements, and no
// requirement that you distribute your changes, although bugfixes and
// enhancements are welcome.
//
// If you do choose to re-distribute the source code, you must retain the
// copyright notice and this license information. I also request that you
// place comments in to identify your changes.
//
// For information on how to use these classes, take a look at the
// included Readme.txt file
// ----------------------------------------------------------------------

#import "SQLitePersistentObject.h"
#import "SQLiteInstanceManager.h"
#import "NSString-SQLiteColumnName.h"
#import "NSObject-SQLitePersistence.h"
#import "NSString-UppercaseFirst.h"
#import "NSString-NumberStuff.h"
#import "NSObject-ClassName.h"
#import "NSObject-MissingKV.h"
#ifdef TARGET_OS_COCOTRON
#import <objc/objc-class.h>
#endif

static id aggregateMethodWithCriteriaImp(id self, SEL _cmd, id value)
{
	NSString *methodBeingCalled = [NSString stringWithUTF8String:sel_getName(_cmd)];
	NSRange rangeOfOf = [methodBeingCalled rangeOfString:@"Of"];
	NSString *operation = [methodBeingCalled substringToIndex:rangeOfOf.location];
    
	if ([operation isEqualToString:@"average"])
		operation = @"avg";
	
	
	NSRange criteriaRange = [methodBeingCalled rangeOfString:@"WithCriteria"];
	NSString *property = nil;
	if (criteriaRange.location == NSNotFound)
	{
		NSRange theRange = NSMakeRange(rangeOfOf.location + rangeOfOf.length, [methodBeingCalled length] - (rangeOfOf.location + rangeOfOf.length));
		property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
	}
	else
	{
		// sumOfamountWithCriteria
		NSRange propRange = NSMakeRange(rangeOfOf.location + rangeOfOf.length, [methodBeingCalled length] - (rangeOfOf.location + rangeOfOf.length) - criteriaRange.length - 1);
		property = [methodBeingCalled substringWithRange:propRange];
	}
	
	
	NSString *query = [NSString stringWithFormat:@"select %@(%@) from %@ %@",operation, [property stringAsSQLColumnName], [self tableName], value];
	double avg = [self performSQLAggregation:query];
	return [NSNumber numberWithDouble:avg];
}
static id aggregateMethodImp(id self, SEL _cmd, id value)
{
	return aggregateMethodWithCriteriaImp(self, _cmd, @"");
}
static id findByMethodImp(id self, SEL _cmd, id value)
{
	NSString *methodBeingCalled = [NSString stringWithUTF8String:sel_getName(_cmd)];
	
	NSRange theRange = NSMakeRange(6, [methodBeingCalled length] - 7);
	NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
	NSMutableString *queryCondition = [NSMutableString stringWithFormat:@"WHERE %@ like ", [property stringAsSQLColumnName]];
	if (![value isKindOfClass:[NSNumber class]])
		[queryCondition appendString:@"'"];
	
	if ([value conformsToProtocol:@protocol(SQLitePersistence)])
	{
		if ([[value class] shouldBeStoredInBlob])
		{
			NSLog(@"*** Can't search on BLOB fields");
			return nil;
		}
		else
			[queryCondition appendString:[value sqlColumnRepresentationOfSelf]];
	}
	else
	{
		[queryCondition appendString:[value stringValue]];
	}
	
	if (![value isKindOfClass:[NSNumber class]])
		[queryCondition appendString:@"'"];
	
	return [self findByCriteria:queryCondition];
}

static int intValue(id object) {
    if (object == [NSNull null]) return 0;
    return [object intValue];
}

static int integerValue(id object) {
    if (object == [NSNull null]) return 0;
    return [object intValue];
}

static int cmpAscending(const void *a, const void *b) {
    char ch1 = *(char*)a;
    char ch2 = *(char*)b;
    if (ch1 < ch2) return -1;
    if (ch1 > ch2) return 1;
    return 0;
}

static BOOL isSqliteIntegerType(char propType) __attribute__((const));
static BOOL isSqliteUnsignedIntegerType(char propType) __attribute__((const));
static BOOL isSqliteSignedIntegerOrBooleanType(char propType) __attribute__((const));
static BOOL isSqliteRealType(char propType) __attribute__((const));
static BOOL isSqliteCharType(char propType) __attribute__((const));
static BOOL isScalarType(char propType) __attribute__((const));

@interface SQLitePersistentObject (private)
+ (void)tableCheck:(FMDatabase *)db;
- (void)setPk:(int)newPk;
+ (NSString *)classNameForTableName:(NSString *)theTable;
//+ (void)setUpDynamicMethods;
- (void)makeClean;
- (void)markDirty;
- (BOOL)isDirty;
@end

static inline BOOL isObjectDirty(SQLitePersistentObject *object) {
    BOOL ret = [object isKindOfClass:[SQLitePersistentObject class]] && [object isDirty];
    return ret;
}


@interface SQLitePersistentObject (private_memory)
+ (NSString *)memoryMapKeyForObject:(NSInteger)thePK;
+ (void)registerObjectInMemory:(SQLitePersistentObject *)theObject;
+ (void)unregisterObject:(SQLitePersistentObject *)theObject;
- (NSString *)memoryMapKey;
@end

NSMutableDictionary *objectMap;
NSMutableArray *checkedTables;

static dispatch_queue_t queue = nil;
static dispatch_queue_t getQueue()
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("sqlite3", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation SQLitePersistentObject

#pragma mark -
#pragma mark Public Class Methods
+ (double)performSQLAggregation: (NSString *)query, ...
{
	double ret = -1.0;
	//sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
	FMDatabase *db = [[SQLiteInstanceManager sharedManager] db];
	// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
	va_list argumentList;
	va_start(argumentList, query);
    
	NSString *queryString = [[NSString alloc] initWithFormat:query arguments:argumentList];
	FMResultSet *result = [db executeQuery:queryString];
    if (result.next) {
        ret = [result doubleForColumn:0];
    }
    [result close];
	return ret;
}

+ (void)clearCache
{
    @synchronized(objectMap) {
        if(objectMap != nil)
            [objectMap removeAllObjects];
	}
    @synchronized(checkedTables) {
        if(checkedTables != nil)
            [checkedTables removeAllObjects];
    }
}

+(NSArray *)indices
{
	return nil;
}

+(NSArray *)transients
{
	return [NSMutableArray array];
}

+(instancetype)findFirstByCriteria:(NSString *)criteriaString, ...
{
	// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
	va_list argumentList;
	va_start(argumentList, criteriaString);
	NSString *queryString = [[NSString alloc] initWithFormat:criteriaString arguments:argumentList];
	NSArray *array = [self findByCriteria:queryString];
	
	if (array != nil)
		if ([array count] > 0)
			return [array objectAtIndex:0];
	return  nil;
}
+ (NSInteger)count
{
    return [self countByCriteria:@""];
}
+ (NSInteger)countByCriteria:(NSString *)criteriaString, ...
{
    __block NSInteger countOfRecords = 0;
    // Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
    va_list argumentList;
    va_start(argumentList, criteriaString);
    NSString *queryString = [[NSString alloc] initWithFormat:criteriaString arguments:argumentList];
    
    NSString *countQuery = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@ %@", [self tableName], queryString];

    [[[SQLiteInstanceManager sharedManager] queryQueue] inDatabase:^(FMDatabase *db) {
        [self tableCheck:db];
        
        FMResultSet *result = [db executeQuery:countQuery];
        if (result.next) {
            countOfRecords = [result intForColumn:0];
        } else {
            NSLog(@"Error determining count of rows in table %@", [db lastError]);
        }
        [result close];
    }];
	return countOfRecords;
}
+(NSArray *)allObjects
{
	return [[self class] findByCriteria:@""];
}

+(void)deleteObject:(NSInteger)inPk cascade:(BOOL)cascade
{
	if(inPk < 0)
		return;
    
	SQLitePersistentObject* objToDelete = [self findByPK:inPk];
	if(objToDelete == nil)
		return;
	
	[objToDelete deleteObjectCascade:cascade];
	
}

+(instancetype)findByPK:(int)inPk
{
	return [self findFirstByCriteria:[NSString stringWithFormat:@"WHERE pk = %d", inPk]];
}

+(NSArray *)findByCriteria:(NSString *)criteriaString, ...
{
    FMDatabaseQueue *queue = [[SQLiteInstanceManager sharedManager] queryQueue];
    [queue inDatabase:^(FMDatabase *db) {
        [[self class] tableCheck:db];
    }];

	NSMutableArray *ret = [NSMutableArray array];
	NSDictionary *theProps = [self propertiesWithEncodedTypes];
	// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
	va_list argumentList;
	va_start(argumentList, criteriaString);
	NSString *queryString = [[NSString alloc] initWithFormat:criteriaString arguments:argumentList];
    va_end(argumentList);
    
    __block NSArray *results;
    NSString *sql = [NSString stringWithFormat:@"SELECT pk,* FROM %@ %@", [self.class tableName], queryString];
    [queue inDatabase:^(FMDatabase *db) {
        FMResultSet *res = [db executeQuery:sql];
        results = [res toArray];
        [res close];
    }];
    
    for (NSDictionary *result in results) {
        NSArray *keys = [result allKeys];
//        @autoreleasepool {
            int pk = [result[@"pk"] intValue];//[result intForColumnIndex:0];
            NSString* memoryMapKey = [[self class] memoryMapKeyForObject:pk];
            id oneItem = [objectMap objectForKey:memoryMapKey];
            if (oneItem) {
                [ret addObject:oneItem];
                // http://clang.llvm.org/docs/AutomaticReferenceCounting.html#autoreleasepool
                continue;
            }
            oneItem = [[[self class] alloc] init];
            [oneItem setPk:pk];
            [[self class] registerObjectInMemory:oneItem];
            
            for (NSString *colName in keys) {
                if ([colName isEqualToString:@"pk"]) {
                    //already set
                    continue;
                } else {
                    NSString *propName = [colName stringAsPropertyString];
                    
                    NSString *colType = [theProps valueForKey:propName];
                    id value = result[colName];
                    if (colType == nil) {
                        break;
                    }
                    char colTypeChar = (char)[colType characterAtIndex:0];
                    if (isSqliteSignedIntegerOrBooleanType(colTypeChar)) {
                        NSNumber *colValue = @([value longLongValue]);
                        [oneItem setValue:colValue forKey:propName];
                    } else if  (isSqliteUnsignedIntegerType(colTypeChar)) {
                        NSNumber *colValue = @([value unsignedLongLongValue]);
                        [oneItem setValue:colValue forKey:propName];
                    } else if (isSqliteRealType(colTypeChar)) {  // double
                        NSNumber *colVal = @([value doubleValue]);
                        [oneItem setValue:colVal forKey:propName];
                    } else if (isSqliteCharType(colTypeChar)) { // unsigned char
                        NSString *colValString = value;//[result stringForColumnIndex:i];
                        
                        if (colValString) {
                            if ([colValString holdsFloatingPointValue]) {
                                NSNumber *number = [NSNumber numberWithDouble:[colValString doubleValue]];
                                [oneItem setValue:number forKey:propName];
                            } else if ([colValString holdsIntegerValue]) {
                                NSNumber *number = [NSNumber numberWithInt:[colValString intValue]];
                                [oneItem setValue:number forKey:propName];
                            } else {
                                [oneItem setValue:colValString forKey:propName];
                            }
                        }
                    } else if (colTypeChar == '@') {
                        NSString *className = [colType substringWithRange:NSMakeRange(2, [colType length]-3)];
                        Class propClass = objc_lookUpClass([className UTF8String]);
                        
                        if ([propClass isSubclassOfClass:[SQLitePersistentObject class]]) {
                            if ([value isKindOfClass:[NSString class]]) {
                            NSString *objMemoryMapKey = value;//[result stringForColumnIndex:i];
                                if(objMemoryMapKey.length > 0) {
                                    NSArray *parts = [objMemoryMapKey componentsSeparatedByString:@"-"];
                                    NSString *classString = [parts objectAtIndex:0];
                                    int fk = [[parts objectAtIndex:1] intValue];
                                    Class propClass = objc_lookUpClass([classString UTF8String]);
                                    id fkObj = [propClass findByPK:fk];
                                    [oneItem setValue:fkObj forKey:propName];
                                }
                            }
                        } else if ([propClass shouldBeStoredInBlob]) {
                            NSData *data = value;//[result dataForColumnIndex:i];
                            id colData = [propClass objectWithSQLBlobRepresentation:data];
                            [oneItem setValue:colData forKey:propName];
                        } else {
                            id colData = nil;
                            NSString *columnText = [value description];//[result stringForColumnIndex:i];
                            if (columnText.length > 0) {
                                colData = [propClass objectWithSqlColumnRepresentation:columnText];
                            }
                            [oneItem setValue:colData forKey:propName];
                        }
                    }
                }
            } //for (i=0; i <  result.columnCount; i++)
            
            // Loop through properties and look for collections classes
            NSArray *theTransients = [[self class] transients];
            for (NSString *propName in theProps)
            {
                if ([theTransients containsObject:propName])
                    continue;
                
                NSString *propType = [theProps objectForKey:propName];
                if ([propType hasPrefix:@"@"]) {
                    NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
                    if (isCollectionType(className)) {
                        if (isNSSetType(className)) {
                            NSMutableSet *set = [NSMutableSet set];
                            /*
                             parent_pk INTEGER, fk INTEGER, fk_table_name TEXT, object_data TEXT
                             */
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [self.class tableName], [propName stringAsSQLColumnName]];
                            NSString *sqlFormat = [NSString stringWithFormat:@"SELECT fk, fk_table_name, object_data, object_class FROM %@ WHERE parent_pk = %%d", tableName];
                            __block NSArray *results = nil;
                            [queue inDatabase:^(FMDatabase *db) {
                                FMResultSet *queryResult = [db executeQueryWithFormat:sqlFormat, [oneItem pk]];
                                results = queryResult.toArray;
                                [queryResult close];
                            }];
                            for (NSDictionary *item in results) {
                                NSNumber *fkNumber = item[@"fk"];
                                int fk;
                                if ([fkNumber isKindOfClass:[NSNumber class]]) {
                                    fk = [item[@"fk"] integerValue];
                                } else {
                                    fk = -1;
                                }
                                if (fk > 0) {
                                    NSString *fkTableName = item[@"fk_table_name"];
                                    if (fkTableName.length == 0) fkTableName = nil;
                                    NSString *propClassName = [[self class] classNameForTableName:fkTableName];
                                    Class propClass = objc_lookUpClass([propClassName UTF8String]);
                                    id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
                                    if (oneObject != nil)
                                        [set addObject:oneObject];
                                } else {
                                    NSString *objectClassName = item[@"object_class"];//[queryResult stringForColumnIndex:3];
                                    
                                    Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
                                    if ([objectClass shouldBeStoredInBlob]) {
                                        NSData *data = item[@"object_data"];
                                        id theObject = [objectClass objectWithSQLBlobRepresentation:data];
                                        [set addObject:theObject];
                                    } else {
                                        NSString *objectData = item[@"object_data"];
                                        id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
                                        [set addObject:theObject];
                                    }
                                }
                            }
                            
                            [oneItem setValue:set forKey:propName];
                        } else if (isNSArrayType(className)) {
                            NSMutableArray *array = [NSMutableArray array];
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [self.class tableName], [propName stringAsSQLColumnName]];
                            NSString *sqlFormat = [NSString stringWithFormat:@"SELECT fk, fk_table_name, object_data, object_class FROM %@ WHERE parent_pk = %%d order by array_index", tableName];
                            
                            __block NSArray *results = nil;
                            [queue inDatabase:^(FMDatabase *db) {
                                FMResultSet *queryResult = [db executeQueryWithFormat:sqlFormat, [oneItem pk]];
                                results = queryResult.toArray;
                                [queryResult close];
                            }];
                            for (NSDictionary *item in results) {
                                int fk = intValue(item[@"fk"]);
                                if (fk > 0) {
                                    NSString *fkTableName = item[@"fk_table_name"] ;
                                    NSString *propClassName = [[self class] classNameForTableName:fkTableName];
                                    Class propClass = objc_lookUpClass([propClassName UTF8String]);
                                    id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
                                    if (oneObject != nil)
                                        [array addObject:oneObject];
                                } else {
                                    NSString *objectClassName = item[@"object_class"];
                                    Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
                                    if ([objectClass shouldBeStoredInBlob]) {
                                        NSData *data = item[@"object_data"];
                                        id theObject = [objectClass objectWithSQLBlobRepresentation:data];
                                        [array addObject:theObject];
                                    } else {
                                        NSString *objectData = item[@"object_data"];
                                        id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
                                        if (theObject)
                                            [array addObject:theObject];
                                    }
                                }
                            }
                            [oneItem setValue:array forKey:propName];
                        } else if (isNSDictionaryType(className)) {
                            NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
                            /* parent_pk integer, dictionary_key TEXT, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class  */
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                            NSString *sqlFormat = [NSString stringWithFormat:@"SELECT dictionary_key, fk, fk_table_name, object_data, object_class FROM %@ WHERE parent_pk = %%d", tableName];
                            
                            __block NSArray *results = nil;
                            [queue inDatabase:^(FMDatabase *db) {
                                FMResultSet *queryResult = [db executeQueryWithFormat:sqlFormat, [oneItem pk]];
                                results = queryResult.toArray;
                                [queryResult close];
                            }];
                            for (NSDictionary *item in results) {
                                NSString *key = item[@"dictionary_key"];
                                int fk = intValue(item[@"fk"]);
                                
                                if (fk > 0) {
                                    NSString *fkTableName = item[@"fk_table_name"];
                                    NSString *propClassName = [[self class] classNameForTableName:fkTableName];
                                    Class propClass = objc_lookUpClass([propClassName UTF8String]);
                                    id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
                                    if (oneObject != nil)
                                        [dictionary setObject:oneObject forKey:key];
                                } else {
                                    NSString *objectClassName = item[@"object_class"];
                                    
                                    Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
                                    if ([objectClass shouldBeStoredInBlob])
                                    {
                                        NSData *data = item[@"object_data"];
                                        id theObject = [objectClass objectWithSQLBlobRepresentation:data];
                                        if (theObject)
                                            [dictionary setObject:theObject forKey:key];
                                    } else {
                                        NSString *objectData = item[@"object_data"];
                                        
                                        id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
                                        if (theObject != nil)
                                            [dictionary setObject:theObject forKey:key];
                                    }
                                }
                            }
                            [oneItem setValue:dictionary forKey:propName];
                        }
                    }
                }
                
            } //for (NSString *propName in theProps)
            [oneItem makeClean];
            [ret addObject:oneItem];
//        } // autoreleasepool
    }
    
	return ret;
}
// This functionality has changed. Now the keys are the PK values, and the values are the values from the specified field. The old version wouldn't allow duplicates because it was using the name as the key, which rather eliminated the usefulness of the method.
+(NSMutableDictionary *)sortedFieldValuesWithKeysForProperty:(NSString *)theProp
{
	NSMutableDictionary *ret = [NSMutableDictionary dictionary];
    FMDatabase *db = [[SQLiteInstanceManager sharedManager] db];
    [[self class] tableCheck:db];
//	sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
	NSString *query = [NSString stringWithFormat:@"SELECT pk, %@ FROM %@ ORDER BY %@, pk", [theProp stringAsSQLColumnName], [[self class] tableName],  [theProp stringAsSQLColumnName]];
    FMResultSet *result = [db executeQuery:query];
    while (result.next) {
        NSNumber *thePK = @([result intForColumnIndex:0]);
        NSString *theName = [result stringForColumnIndex:1];
        [ret setObject:theName forKey:[thePK stringValue]];
	}
    [result close];
	return ret;
}
+(NSArray *)pairedArraysForProperties:(NSArray *)theProps
{
	return [self pairedArraysForProperties:theProps withCriteria:@""];
}
+(NSArray *)pairedArraysForProperties:(NSArray *)theProps withCriteria:(NSString *)criteriaString, ...
{
	FMDatabase *db = [[SQLiteInstanceManager sharedManager]db];
	NSMutableArray *ret = [NSMutableArray array];
	[[self class] tableCheck:db];
	
//	sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
	NSMutableString *query = [NSMutableString stringWithString:@"select pk"];
	
	for (NSString *oneProp in theProps)
		[query appendFormat:@", %@", [oneProp stringAsSQLColumnName]];
	
	// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
	va_list argumentList;
	va_start(argumentList, criteriaString);
	NSString *queryString = [[NSString alloc] initWithFormat:criteriaString arguments:argumentList];
	
	[query appendFormat:@" FROM %@ %@ ORDER BY PK", [[self class] tableName], queryString];
	
	for (int i = 0; i <= [theProps count]; i++)
		[ret addObject:[NSMutableArray array]];

	FMResultSet *result = [db executeQuery:query];
    while (result.next) {
        NSNumber *thePK = @([result intForColumnIndex:0]);
        [[ret objectAtIndex:0] addObject:thePK];
        
        for (int i = 1; i <= [theProps count]; i++) {
            NSMutableArray *fieldArray = [ret objectAtIndex:i];
            NSString *theValue = [result stringForColumnIndex:i];
            if (theValue) {
                [fieldArray addObject:theValue];
            } else {
                [fieldArray addObject:[NSNull null]];
            }
        }
    }
	[result close];
	return ret;
}
#ifdef TARGET_OS_COCOTRON
+ (NSArray *)getPropertiesList
{
	return [NSArray array];
}
#endif

+(NSDictionary *)propertiesWithEncodedTypes
{
    static NSLock *lock = nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
        cache = [[NSMutableDictionary alloc] initWithCapacity:32];
    });
    
	// Recurse up the classes, but stop at NSObject. Each class only reports its own properties, not those inherited from its superclass
	NSMutableDictionary *theProps;
	[lock lock];
    theProps = [cache valueForKey:NSStringFromClass([self class])];
    [lock unlock];
    if (theProps) {
        return theProps;
    } else {
        [lock lock];
        theProps = [[NSMutableDictionary alloc] initWithCapacity:4];
        [cache setValue:theProps forKey:NSStringFromClass([self class])];
        [lock unlock];
    }
    
	if ([self superclass] != [NSObject class])
		[theProps addEntriesFromDictionary: (NSMutableDictionary *)[[self superclass] propertiesWithEncodedTypes]];
	
	unsigned int outCount;
	
#ifndef TARGET_OS_COCOTRON
	objc_property_t *propList = class_copyPropertyList([self class], &outCount);
#else
	NSArray *propList = [[self class] getPropertiesList];
	outCount = [propList count];
#endif
	int i;
	
	// Loop through properties and add declarations for the create
	for (i=0; i < outCount; i++)
	{
#ifndef TARGET_OS_COCOTRON
		objc_property_t oneProp = propList[i];
		NSString *propName = [NSString stringWithUTF8String:property_getName(oneProp)];
		NSString *attrs = [NSString stringWithUTF8String: property_getAttributes(oneProp)];
		// Read only attributes are assumed to be derived or calculated
		// See http://developer.apple.com/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/chapter_8_section_3.html
		if ([attrs rangeOfString:@",R,"].location == NSNotFound)
		{
			NSArray *attrParts = [attrs componentsSeparatedByString:@","];
			if (attrParts != nil)
			{
				if ([attrParts count] > 0)
				{
					NSString *propType = [[attrParts objectAtIndex:0] substringFromIndex:1];
					[theProps setObject:propType forKey:propName];
				}
			}
		}
#else
		NSArray *oneProp = [propList objectAtIndex:i];
		NSString *propName = [oneProp objectAtIndex:0];
		NSString *attrs = [oneProp objectAtIndex:1];
		[theProps setObject:attrs forKey:propName];
#endif
	}
	
#ifndef TARGET_OS_COCOTRON
	free( propList );
#endif
	
	return theProps;
}
#pragma mark -
#pragma mark Public Instance Methods
-(int)pk
{
	return pk;
}

- (void)_save:(FMDatabase *)db
{
    if (alreadySaving)
		return;
	alreadySaving = YES;
	
	[[self class] tableCheck:db];
	
    if (pk == 0)
    {
        NSLog(@"Object of type '%@' seems to be uninitialised, perhaps init does not call super init.", [[self class] description] );
        return;
    }
	
	NSDictionary *props = [[self class] propertiesWithEncodedTypes];
    
	if (!dirty)
	{
		// Check child and owned objects to see if any of them are dirty
		// Just tell children and composed objects to save themselves
		
		for (NSString *propName in props) {
			NSString *propType = [props objectForKey:propName];
			id theProperty = [self valueForKey:propName];
			if ([propType hasPrefix:@"@"] ) // Object
			{
				NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
				if (! (isCollectionType(className)) )
				{
					if ([[theProperty class] isSubclassOfClass:[SQLitePersistentObject class]])
						if ([theProperty isDirty])
							dirty = YES;
				} else if (isNSSetType(className) || isNSArrayType(className)) {
                    for (id oneObject in (NSArray *)theProperty) {
                        if ([oneObject isKindOfClass:[SQLitePersistentObject class]]) {
                            if ([oneObject isDirty]) {
                                dirty = YES;
                            } else if (isNSDictionaryType(className)) {
                                [theProperty enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                                    dirty = isObjectDirty(obj);
                                    if (dirty) {
                                        *stop = YES;
                                    }
                                }];
                            }
                            if (dirty) break;
                        }
                    }
				}
			}
            if (dirty) break;
		}
    }
    
    NSArray *theTransients = [[self class] transients];
    if (dirty) {
        dirty = NO;
        // If this object is new, we need to figure out the correct primary key value,
        // which will be one higher than the current highest pk value in the table.
        
        if (pk < 0)
        {
            NSString *pkQuery = @"SELECT SEQ FROM SQLITESEQUENCE WHERE NAME=?";
            FMResultSet *result = [db executeQuery:pkQuery, [[self class] tableName]];
            if (result.next) {
                pk = [result intForColumnIndex:0] + 1;
            }
            [result close];
            if (result) {
                NSString *seqIncrementQuery = @"UPDATE SQLITESEQUENCE set seq=? WHERE name=?";
                if (![db executeUpdate:seqIncrementQuery, @(pk), [[self class] tableName]]) {
                    NSLog(@"Error Message: %@", [db lastError]);
                }
            } else {
                NSLog(@"Error determining next PK value in table %@", [[self class] tableName]);
            }
        }
    }
    NSMutableString *updateSQL = [NSMutableString stringWithFormat:@"INSERT OR REPLACE INTO %@ (pk", [[self class] tableName]];
    
    NSMutableString *bindSQL = [NSMutableString string];
    
    for (NSString *propName in props)
    {
        if ([theTransients containsObject:propName]) continue;
        
        NSString *propType = [props objectForKey:propName];
        NSString *className = @"";
        if ([propType hasPrefix:@"@"])
            className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
        if (! (isCollectionType(className)))
        {
            [updateSQL appendFormat:@", %@", [propName stringAsSQLColumnName]];
            [bindSQL appendString:@", ?"];
        }
    }
    
    [updateSQL appendFormat:@") VALUES (?%@)", bindSQL];
    
    NSMutableArray *paramsArray = [NSMutableArray arrayWithCapacity:16];
    
    [paramsArray addObject:@(pk)];
    int dbg_count = 1;
    for (NSString *propName in props) {
        if ([theTransients containsObject:propName]) {
            continue;
        }
        
        NSString *propType = [props objectForKey:propName];
        char propTypeChar = (char)[propType characterAtIndex:0];
        NSString *className = propType;
        if ([propType hasPrefix:@"@"])
            className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
        id theProperty = [self valueForKey:propName];
        if (theProperty == nil && ! (isCollectionType(className))) {
            [paramsArray addObject:[NSNull null]];
        } else if (isScalarType(propTypeChar)) {  // integer / char / double / boolean
            [paramsArray addObject:[theProperty stringValue]];
        } else if (propTypeChar ==  '@') { // Object
            if (! (isCollectionType(className)) ) {
                if ([[theProperty class] isSubclassOfClass:[SQLitePersistentObject class]])
                {
                    [theProperty _save:db];
                    [paramsArray addObject:[theProperty memoryMapKey]];
                } else if ([[theProperty class] shouldBeStoredInBlob]){
                    NSData *data = [theProperty sqlBlobRepresentationOfSelf];
                    [paramsArray addObject:data];
                } else {
                    [paramsArray addObject:[theProperty sqlColumnRepresentationOfSelf]];
                }
            } else {
                // Too difficult to try and figure out what's changed, just wipe rows and re-insert the current data.
                NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                NSString *xrefDelete = [NSString stringWithFormat:@"delete from %@ where parent_pk = ?", tableName];
                //						char *errmsg = NULL;
                if (![db executeUpdate:xrefDelete, @(pk)]) {
                    NSLog(@"Error deleting child rows in xref table for array: %@", db.lastError);
                }
                
                if (isNSArrayType(className))
                {
                    int arrayIndex = 0;
                    for (id oneObject in (NSArray *)theProperty)
                    {
                        if ([oneObject isKindOfClass:[SQLitePersistentObject class]])
                        {
                            [oneObject _save:db];
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                            
                            NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@ (parent_pk, array_index, fk, fk_table_name) values (%d, %d, %d, '%@')", tableName,  pk, arrayIndex++, [oneObject pk], [[oneObject class] tableName]];
                            if (![db executeUpdate:xrefInsert]) {
                                NSLog(@"Error inserting child rows in xref table for array: %@", db.lastError);
                            }
                        }
                        else
                        {
                            if ([[oneObject class] canBeStoredInSQLite])
                            {
                                NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                                NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@ (parent_pk, array_index, object_data, object_class) values (%d, %d, ?, '%@')", tableName, pk, arrayIndex++, [oneObject className]];
                                NSMutableArray *params = [NSMutableArray arrayWithCapacity:2];
                                if ([[oneObject class] shouldBeStoredInBlob])
                                {
                                    NSData *data = [oneObject sqlBlobRepresentationOfSelf];
                                    [params addObject:data];
                                }
                                else
                                {
                                    [params addObject:[oneObject sqlColumnRepresentationOfSelf]];
                                }
                                if (![db executeUpdate:xrefInsert withArgumentsInArray:params]) {
                                    NSLog(@"Error inserting or updating cross-reference row: %@", [db lastError]);
                                }
                            }
                            else
                                NSLog(@"Could not save object at array index: %d", arrayIndex++);
                        }
                    }
                }
                else if (isNSDictionaryType(className))
                {
                    for (NSString *oneKey in (NSDictionary *)theProperty)
                    {
                        id oneObject = [(NSDictionary *)theProperty objectForKey:oneKey];
                        if ([(NSObject *)oneObject isKindOfClass:[SQLitePersistentObject class]])
                        {
                            [(SQLitePersistentObject *)oneObject _save:db];
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                            NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@ (parent_pk, dictionary_key, fk, fk_table_name) values (%d, '%@', %d, '%@')",  tableName, pk, oneKey, [(SQLitePersistentObject *)oneObject pk], [[oneObject class] tableName]];
                            if (![db executeUpdate:xrefInsert]) {
                                NSLog(@"Error inserting child rows in xref table for array: %@", db.lastError);
                            }
                        } else {
                            if ([[oneObject class] canBeStoredInSQLite])
                            {
                                NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                                NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@(parent_pk, dictionary_key, object_data, object_class) values (%d, '%@', ?, '%@')", tableName, pk, oneKey, [oneObject className]];
                                NSMutableArray *params = [NSMutableArray arrayWithCapacity:1];
                                
                                if ([[oneObject class] shouldBeStoredInBlob])
                                {
                                    NSData *data = [oneObject sqlBlobRepresentationOfSelf];
                                    [params addObject:data];
                                } else {
                                    [params addObject:[oneObject sqlColumnRepresentationOfSelf]];
                                }
                                
                                if (![db executeUpdate:xrefInsert withArgumentsInArray:params]) {
                                    NSLog(@"Error inserting or updating cross-reference row: %@", db.lastError);
                                }
                            }
                        }
                    }
                }
                else // NSSet
                {
                    for (id oneObject in (NSSet *)theProperty)
                    {
                        if ([oneObject isKindOfClass:[SQLitePersistentObject class]])
                        {
                            [oneObject _save:db];
                            NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                            NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@ (parent_pk, fk, fk_table_name) values (%d, ?, '%@')", tableName,  pk, [[oneObject class] tableName]];
                            if (![db executeUpdate:xrefInsert, [oneObject sqlBlobRepresentationOfSelf]]) {
                                NSLog(@"Error inserting child rows in xref table for array: %@", db.lastError);
                            }
                        } else {
                            if ([[oneObject class] canBeStoredInSQLite])
                            {
                                NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [propName stringAsSQLColumnName]];
                                NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@ (parent_pk, object_data, object_class) values (%d,  ?, '%@')", tableName, pk, [oneObject className]];
                                NSMutableArray *params = [NSMutableArray arrayWithCapacity:1];
                                
                                if ([[oneObject class] shouldBeStoredInBlob])
                                {
                                    NSData *data = [oneObject sqlBlobRepresentationOfSelf];
                                    [params addObject:data];
                                } else {
                                    [params addObject:[oneObject sqlColumnRepresentationOfSelf]];
                                }
                                if (![db executeUpdate:xrefInsert withArgumentsInArray:params]) {
                                    NSLog(@"Error inserting or updating cross-reference row: %@", db.lastError);
                                }
                                
                            } else {
                                NSLog(@"Could not save object from set");
                            }
                        }
                    }
                }
            }
        }
        ++dbg_count;
//        NSAssert(dbg_count == paramsArray.count, @"som");
    }
    if (![db executeUpdate:updateSQL withArgumentsInArray:paramsArray]) {
        NSLog(@"Error inserting or updating row");
    }
    
    // Can't register in memory map until we have PK, so do that now.
    if (![[objectMap allKeys] containsObject:[self memoryMapKey]])
        [[self class] registerObjectInMemory:self];
    
	alreadySaving = NO;
}
-(void)save
{
    FMDatabaseQueue *queue = [[SQLiteInstanceManager sharedManager] saveQueue];
    [queue inDatabase:^(FMDatabase *db) {
        [self _save:db];
    }];
    /*
    [queue inDatabase:^(FMDatabase *db) {
        [self _save:db];
    }];
     */
}

/*
 * Reverts the object back to database state. Any changes that have been
 * made since the object was loaded are undone.
 */
-(void)revert
{
	if(![self existsInDB])
	{
		NSLog(@"Object must exist in database before it can be reverted.");
		return;
	}
	
	[[self class] unregisterObject:self];
	SQLitePersistentObject* dbObj = [[self class] findByPK:[self pk]];
	for(NSString *fieldName in [[self class] propertiesWithEncodedTypes])
	{
		if([dbObj valueForKey:fieldName] != [self valueForKey:fieldName])
			[self setValue:[dbObj valueForKey:fieldName] forKey:fieldName];
	}
	[[self class] registerObjectInMemory:self];
}

/*
 * Reverts the given field name back to its database state.
 */
-(void)revertProperty:(NSString *)propName
{
	if(![self existsInDB])
	{
		NSLog(@"Object must exist in database before it can be reverted.");
		return;
	}
	
	[[self class] unregisterObject:self];
	SQLitePersistentObject* dbObj = [[self class] findByPK:[self pk]];
	if([dbObj valueForKey:propName] != [self valueForKey:propName])
		[self setValue:[dbObj valueForKey:propName] forKey:propName];
	[[self class] registerObjectInMemory:self];
}

/*
 * Reverts an NSArray of field names back to their database states.
 */
-(void)revertProperties:(NSArray *)propNames
{
	if(![self existsInDB])
	{
		NSLog(@"Object must exist in database before it can be reverted.");
		return;
	}
	
	[[self class] unregisterObject:self];
	SQLitePersistentObject* dbObj = [[self class] findByPK:[self pk]];
	for(NSString *fieldName in propNames)
	{
		if([dbObj valueForKey:fieldName] != [self valueForKey:fieldName])
			[self setValue:[dbObj valueForKey:fieldName] forKey:fieldName];
	}
	[[self class] registerObjectInMemory:self];
}

-(BOOL) existsInDB
{
    // pk must be greater than 0 if its on the db
	return pk > 0;
}
-(void)deleteObject
{
	[self deleteObjectCascade:NO];
}
- (void)deleteObjectCascade:(BOOL)cascade
{
    [[[SQLiteInstanceManager sharedManager] saveQueue] inDatabase:^(FMDatabase *db) {
        [self deleteObjectCascade:cascade withDB:db];
    }];
}
-(void)deleteObjectCascade:(BOOL)cascade withDB:(FMDatabase *)db
{
	if(pk < 0)
		return;
	
	if(alreadyDeleting)
		return;
	alreadyDeleting = TRUE;
	//Primary key set implies object already saved and table checked
	//[self tableCheck];
	
	[[self class] unregisterObject:self];
	
	NSString *deleteQuery = [NSString stringWithFormat:@"DELETE FROM %@ WHERE pk = ?", [[self class] tableName]];

    
    void (^operation)(FMDatabase *db) = ^(FMDatabase *db) {
        if (![db executeUpdate:deleteQuery, @(pk)]) {
            NSLog(@"Error deleting row in table: %@", db.lastError);
        }
        
        NSDictionary *theProps = [[self class] propertiesWithEncodedTypes];

        for (NSString *prop in [theProps allKeys])
        {
            NSString *colType = [theProps valueForKey:prop];
            if ([colType hasPrefix:@"@"])
            {
                NSString *className = [colType substringWithRange:NSMakeRange(2, [colType length]-3)];
                if (isCollectionType(className))
                {
                    if (cascade)
                    {
                        NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [prop stringAsSQLColumnName]];
                        NSString *xRefLoopQuery = [NSString stringWithFormat:@"select fk_table_name, fk from %@ where parent_pk = ?", tableName];
                        FMResultSet *result = [db executeQuery:xRefLoopQuery, @(pk)];
                        NSArray *resultArr = [result toArray];
                        [result close];
                        for (NSDictionary *dict in resultArr) {
                            NSString *fkTableString = dict[@"fk_table_name"];
                            if (![fkTableString isKindOfClass:[NSString class]] || [fkTableString length] == 0) {
                                continue;
                            }
                            int fk_value = [dict[@"fk"] intValue];
                            if (fkTableString)
                            {
                                NSString *xRefDeleteQuery = [NSString stringWithFormat:@"delete from %@ where pk = ?",fkTableString];
                                if (![db executeUpdate:xRefDeleteQuery, @(fk_value)]) {
                                    NSLog(@"Error deleting foreign key rows in table: %@", db.lastError);
                                }
                            }
                        }
                    }
                    NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], [prop stringAsSQLColumnName]];
                    NSString *xRefDeleteQuery = [NSString stringWithFormat:@"DELETE FROM %@ WHERE parent_pk = ?", tableName];
                    if (![db executeUpdate:xRefDeleteQuery, @(pk)]) {
                        NSLog(@"Error deleting from foreign key table: %@", db.lastError);
                    }
                }
                else
                {
                    Class propClass = objc_lookUpClass([className UTF8String]);
                    if ([propClass isSubclassOfClass:[SQLitePersistentObject class]] && cascade)
                    {
                        id theProperty = [self valueForKey:prop];
                        [theProperty deleteObjectCascade:cascade withDB:db];
                    }
                }
                
            }
        }
        alreadyDeleting = FALSE;
    };
    if (db) {
        operation(db);
    } else {
        [[[SQLiteInstanceManager sharedManager] saveQueue] inDatabase:operation];
    }
}
-(void)deleteForeignObjects:(Class)cls
{
    [cls deleteObjectsByCriteria:@"%@ = '%@'", [[self class] tableName], [self memoryMapKey]];
}
+(void)deleteObjectsByCriteria:(NSString*)criteriaString, ...
{
    NSString* q = [NSString stringWithFormat:@"DELETE FROM %@", [[self class] tableName]];
    if (criteriaString)
    {
        va_list argumentList;
        va_start(argumentList, criteriaString);
        NSString* criteria = [[NSString alloc] initWithFormat:criteriaString arguments:argumentList];
        q = [q stringByAppendingFormat:@" WHERE %@", criteria];
    }
    
    FMDatabaseQueue *queue = [[SQLiteInstanceManager sharedManager] queryQueue];
    [queue inDatabase:^(FMDatabase *db) {        
        if (![db executeUpdate:q]) {
            NSLog(@"Error deleting from table: %@", db.lastError);
        }
    }];
}

- (NSArray *)findRelated:(Class)cls forProperty:(NSString *)prop filter:(NSString *)filter, ...
{
	NSString *q = [NSString stringWithFormat:@"WHERE %@ = \"%@\"", prop, [self memoryMapKey]];
	if(filter)
	{
		// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
		va_list argumentList;
		va_start(argumentList, filter);
		NSString *queryString = [[NSString alloc] initWithFormat:filter arguments:argumentList];
		q = [q stringByAppendingFormat:@" AND %@", queryString];
	}
    
	return [cls findByCriteria:q];
}

- (NSArray *)findRelated:(Class)cls filter:(NSString *)filter, ...
{
	// Added variadic ability to all criteria accepting methods -SLyons (10/03/2009)
	va_list argumentList;
	va_start(argumentList, filter);
	NSString *queryString = [[NSString alloc] initWithFormat:filter arguments:argumentList];
	return [self findRelated:cls forProperty:[[self class] tableName] filter:queryString];
}

- (NSArray *)findRelated:(Class)cls
{
	return [self findRelated:cls forProperty:[[self class] tableName] filter:nil];
}

#pragma mark -
#pragma mark NSObject Overrides
+ (BOOL)resolveClassMethod:(SEL)theMethod
{
	@synchronized(self)
	{
		const char *methodName = sel_getName(theMethod);
		NSString *methodBeingCalled = [NSString stringWithUTF8String:methodName];
		
		if ([methodBeingCalled hasPrefix:@"findBy"])
		{
			NSRange theRange = NSMakeRange(6, [methodBeingCalled length] - 7);
			NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
			NSDictionary *properties = [self propertiesWithEncodedTypes];
			NSLog(@"Property: %@", property);
			if ([[properties allKeys] containsObject:property])
			{
				SEL newMethodSelector = sel_registerName([methodBeingCalled UTF8String]);
				
				// Hardcore juju here, this is not documented anywhere in the runtime (at least no
				// anywhere easy to find for a dope like me), but if you want to add a class method
				// to a class, you have to get the metaclass object and add the clas to that. If you
				// add the method
#ifndef TARGET_OS_COCOTRON
				Class selfMetaClass = objc_getMetaClass([[self className] UTF8String]);
				return (class_addMethod(selfMetaClass, newMethodSelector, (IMP) findByMethodImp, "@@:@")) ? YES : [super resolveClassMethod:theMethod];
#else
				if(class_getClassMethod([self class], newMethodSelector) != NULL) {
					return [super resolveClassMethod:theMethod];
				} else {
					BOOL isNewMethod = YES;
					Class selfMetaClass = objc_getMetaClass([[self className] UTF8String]);
					
					
					struct objc_method *newMethod = calloc(sizeof(struct objc_method), 1);
					struct objc_method_list *methodList = calloc(sizeof(struct objc_method_list)+sizeof(struct objc_method), 1);
					
					newMethod->method_name = newMethodSelector;
					newMethod->method_types = "@@:@";
					newMethod->method_imp = (IMP) findByMethodImp;
					
					methodList->method_next = NULL;
					methodList->method_count = 1;
					memcpy(methodList->method_list, newMethod, sizeof(struct objc_method));
					free(newMethod);
					class_addMethods(selfMetaClass, methodList);
					
					assert(isNewMethod);
					return YES;
				}
#endif
			}
			else
				return [super resolveClassMethod:theMethod];
		}
		else if ([methodBeingCalled rangeOfString:@"Of"].location != NSNotFound)
		{
			NSRange rangeOfOf = [methodBeingCalled rangeOfString:@"Of"];
			NSString *operation = [methodBeingCalled substringToIndex:rangeOfOf.location];
			if ([operation isEqualToString:@"sum"] || [operation isEqualToString:@"avg"]
				|| [operation isEqualToString:@"average"] || [operation isEqualToString:@"min"]
				|| [operation isEqualToString:@"max"] || [operation isEqualToString:@"count"])
			{
				NSRange criteriaRange = [methodBeingCalled rangeOfString:@"WithCriteria"];
				if (criteriaRange.location == NSNotFound)
				{
					// Do for all
					NSRange theRange = NSMakeRange(rangeOfOf.location + rangeOfOf.length, [methodBeingCalled length] - (rangeOfOf.location + rangeOfOf.length));
					NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
					NSDictionary *properties = [self propertiesWithEncodedTypes];
					if ([[properties allKeys] containsObject:property])
					{
						SEL newMethodSelector = sel_registerName([methodBeingCalled UTF8String]);
						Class selfMetaClass = objc_getMetaClass([[self className] UTF8String]);
						return (class_addMethod(selfMetaClass, newMethodSelector, (IMP) aggregateMethodImp, "@@:")) ? YES : [super resolveClassMethod:theMethod];
					}
				}
				else
				{
					// do with criteria
					NSRange theRange = NSMakeRange(rangeOfOf.location + rangeOfOf.length, [methodBeingCalled length] - criteriaRange.length - (rangeOfOf.length + rangeOfOf.location) - 1);
					NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
					NSDictionary *properties = [self propertiesWithEncodedTypes];
					if ([[properties allKeys] containsObject:property])
					{
						SEL newMethodSelector = sel_registerName([methodBeingCalled UTF8String]);
						Class selfMetaClass = objc_getMetaClass([[self className] UTF8String]);
						return (class_addMethod(selfMetaClass, newMethodSelector, (IMP) aggregateMethodWithCriteriaImp, "@@:@")) ? YES : [super resolveClassMethod:theMethod];
					}
				}
			}
		}
		return [super resolveClassMethod:theMethod];
	}
	return NO;
}
-(id)init
{
	if ((self=[super init]))
	{
		pk = -1;
		dirty = YES;
		alreadySaving = NO;
		for (NSString *oneProp in [[self class] propertiesWithEncodedTypes])
			[self addObserver:self forKeyPath:oneProp options:0 context:nil];
		
		
	}
	return self;
}
- (void)dealloc
{
	[[self class] unregisterObject:self];
    
    for (NSString *oneProp in [[self class] propertiesWithEncodedTypes])
        [self removeObserver:self forKeyPath:oneProp];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	dirty = YES;
}
#pragma mark -
#pragma mark Private Methods
+ (NSString *)classNameForTableName:(NSString *)theTable
{
	static NSMutableDictionary *classNamesForTables = nil;
	
	if (classNamesForTables == nil)
		classNamesForTables = [[NSMutableDictionary alloc] init];
	
	if ([[classNamesForTables allKeys] containsObject:theTable])
		return [classNamesForTables objectForKey:theTable];
	
	
	NSMutableString *ret = [NSMutableString string];
	
	BOOL lastCharacterWasUnderscore = NO;
	for (int i = 0; i < theTable.length; i++)
	{
		NSRange range = NSMakeRange(i, 1);
		NSString *oneChar = [theTable substringWithRange:range];
		if ([oneChar isEqualToString:@"_"])
			lastCharacterWasUnderscore = YES;
		else
		{
			if (lastCharacterWasUnderscore || i == 0)
				[ret appendString:[oneChar uppercaseString]];
			else
				[ret appendString:oneChar];
			
			lastCharacterWasUnderscore = NO;
		}
	}
	[classNamesForTables setObject:ret forKey:theTable];
	
	return ret;
}
- (void)markDirty
{
	dirty = YES;
}
- (void)makeClean
{
	dirty = NO;
}
- (BOOL)isDirty
{
	return dirty;
}
+ (NSString *)tableName
{
	static NSMutableDictionary *tableNamesByClass = nil;

	@synchronized(self) {
        if (tableNamesByClass == nil)
            tableNamesByClass = [[NSMutableDictionary alloc] init];
        
        if ([[tableNamesByClass allKeys] containsObject:[self className]])
            return [tableNamesByClass objectForKey:[self className]];
	}
	// Note: Using a static variable to store the table name
	// will cause problems because the static variable will
	// be shared by instances of classes and their subclasses
	// Cache in the instances, not here...
	NSMutableString *ret = [NSMutableString string];
	NSString *className = [self className];
	for (int i = 0; i < className.length; i++)
	{
		NSRange range = NSMakeRange(i, 1);
		NSString *oneChar = [className substringWithRange:range];
		if ([oneChar isEqualToString:[oneChar uppercaseString]] && i > 0)
			[ret appendFormat:@"_%@", [oneChar lowercaseString]];
		else
			[ret appendString:[oneChar lowercaseString]];
	}
	
	[tableNamesByClass setObject:ret forKey:[self className]];
	return ret;
}

+ (NSArray *)tableColumns:(FMDatabase *)db
{
	NSMutableArray *ret = [NSMutableArray array];
	// pragma table_info(i_c_project);
	NSString *query = [NSString stringWithFormat:@"pragma table_info(%@);", [self tableName]];
    FMResultSet *result = [db executeQuery:query];

    while (result.next)
    {
        NSString *colString = [result stringForColumnIndex:1];
        [ret addObject:colString];
    }
    [result close];
	return ret;
}

+(void)tableCheck:(FMDatabase *)db
{
    NSArray *theTransients = [[self class] transients];
	
	if (checkedTables == nil)
		checkedTables = [[NSMutableArray alloc] init];
	
	if (![checkedTables containsObject:[self className]])
	{
		[checkedTables addObject:[self className]];
		
		// Do not use static variables to cache information in this method, as it will be
		// shared across subclasses. Do caching in instance methods.
		NSMutableString *createSQL = [NSMutableString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (pk INTEGER PRIMARY KEY",[self tableName]];
		
		NSDictionary* props = [[self class] propertiesWithEncodedTypes];
		for (NSString *oneProp in props)
		{
			if ([theTransients containsObject:oneProp]) continue;
			
			NSString *propName = [oneProp stringAsSQLColumnName];
			
			NSString *propType = [props objectForKey:oneProp];
            unichar propTypeChar = [propType characterAtIndex:0];
            
			// Integer Types
            if (isSqliteIntegerType(propTypeChar)) {
				[createSQL appendFormat:@", %@ INTEGER", propName];
			}
			// Character Types
			else if (isSqliteCharType(propTypeChar)) {
				[createSQL appendFormat:@", %@ TEXT", propName];
			}
            // Real Types
			else if (isSqliteRealType(propTypeChar))
			{
				[createSQL appendFormat:@", %@ REAL", propName];
			}
			else if (propTypeChar == '@') // Object
			{
                NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
				
				// Collection classes have to be handled differently. Instead of adding a column, we add a child table.
				// Child tables will have a field for holding data and also a non-required foreign key field. If the
				// object stored in the collection is a subclass of SQLitePersistentObject, then it is stored as
				// a reference to the row in the table that holds the object. If it's not, then it is stored
				// in the field using the SQLitePersistence protocol methods. If it's not a subclass of
				// SQLitePersistentObject and doesn't conform to NSCoding then the object won't get persisted.
				if (isNSArrayType(className))
				{
                    NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], propName];

					NSString *xRefQuery = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (parent_pk, array_index INTEGER, fk INTEGER, fk_table_name TEXT, object_data TEXT, object_class BLOB, PRIMARY KEY (parent_pk, array_index))", tableName];
                    if (![db executeUpdate:xRefQuery]) {
						NSLog(@"Error Message: %@", db.lastError);
                    }
				}
				else if (isNSDictionaryType(className))
				{
                    NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], propName];

					NSString *xRefQuery = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (parent_pk integer, dictionary_key TEXT, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class TEXT, PRIMARY KEY (parent_pk, dictionary_key))", tableName];
                    if (![db executeUpdate:xRefQuery]) {
						NSLog(@"Error Message: %@", db.lastError);
                    }
				}
				else if (isNSSetType(className))
				{
                    NSString *tableName = [NSString stringWithFormat:@"%@_%@", [[self class] tableName], propName];
                    NSString *sql = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (parent_pk INTEGER, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class TEXT)", tableName];
                    if (![db executeUpdate:sql]) {
						NSLog(@"Error Message: %@", db.lastError);
                    }
				}
				else
				{
					Class propClass = objc_lookUpClass([className UTF8String]);
					
					if ([propClass isSubclassOfClass:[SQLitePersistentObject class]])
					{
						// Store persistent objects as quasi foreign-key reference. We don't use
						// datbase's referential integrity tools, but rather use the memory map
						// key to store the table and fk in a single text field
						[createSQL appendFormat:@", %@ TEXT", propName];
					}
					else if ([propClass canBeStoredInSQLite])
					{
						[createSQL appendFormat:@", %@ %@", propName, [propClass columnTypeForObjectStorage]];
					}
				}
				
			}
		}
		[createSQL appendString:@")"];
		
        if (![db executeUpdate:createSQL]) {
            NSLog(@"Error Message: %@", db.lastError);
        }
		if (![db executeUpdate:@"CREATE TABLE IF NOT EXISTS SQLITESEQUENCE (name TEXT PRIMARY KEY, seq INTEGER)"]) {
            NSLog(@"Error Message: %@", db.lastError);
        }
		
		NSMutableString *addSequenceSQL = [NSMutableString stringWithFormat:@"INSERT OR IGNORE INTO SQLITESEQUENCE (name,seq) VALUES ('%@', 0)", [[self class] tableName]];
        if (![db executeUpdate:addSequenceSQL]) {
			NSLog(@"Error Message: %@", db.lastError);
        }
        
		NSArray *theIndices = [self indices];
		if (theIndices != nil)
		{
			if ([theIndices count] > 0)
			{
				for (NSArray *oneIndex in theIndices)
				{
					NSMutableString *indexName = [NSMutableString stringWithString:[self tableName]];
					NSMutableString *fieldCondition = [NSMutableString string];
					BOOL first = YES;
					for (NSString *oneField in oneIndex)
					{
						[indexName appendFormat:@"_%@", [oneField stringAsSQLColumnName]];
						
						if (first)
							first = NO;
						else
							[fieldCondition appendString:@", "];
						[fieldCondition appendString:[oneField stringAsSQLColumnName]];
					}
					NSString *indexQuery = [NSString stringWithFormat:@"create index if not exists %@ on %@ (%@)", indexName, [self tableName], fieldCondition];
                    if (![db executeUpdate:indexQuery]) {
                        NSLog(@"Error creating indices on %@: %@", [self tableName], db.lastError);
                    }
				}
			}
		}
		
		// Now, make sure that every property has a corresponding column, alter the table for any that are missing
		NSArray *tableCols = [self tableColumns:db];
		for (NSString *oneProp in props)
		{
			if ([theTransients containsObject:oneProp]) continue;
			
			NSString *propName = [oneProp stringAsSQLColumnName];
			if (![tableCols containsObject:propName])
			{
				// No underlying column - could be a collection
				NSString *propType = [[[self class] propertiesWithEncodedTypes] objectForKey:oneProp];
                char propTypeChar = [propType characterAtIndex:0];
				if (propTypeChar == '@') {
					NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
					if (isNSArrayType(className) || isNSDictionaryType(className) || isNSSetType(className))
					{
						// It's a collection, it's okay for there to be no column, and we don't even need to
						// check if it exists, because we used create if not exists above, so it will get created
						// no matter what. I'm going to leave the if clause and this comment here though so
						// nobody spends time doing unnecessary work implementing this...
					}
					else
					{
						Class propClass = objc_lookUpClass([className UTF8String]);
						NSString *colType = nil;
						
						if ([propClass isSubclassOfClass:[SQLitePersistentObject class]])
							colType = @"TEXT";
						else if ([propClass canBeStoredInSQLite])
							colType = [propClass columnTypeForObjectStorage];
						
						[[SQLiteInstanceManager sharedManager] executeUpdateSQL:[NSString stringWithFormat:@"alter table %@ add column %@ %@", [self tableName], propName, colType]];
					}
				}
				else
				{
					// TODO: Refactor out the col-type for property type into a single method or inline function
					NSString *colType = @"TEXT";
					if (isSqliteIntegerType(propTypeChar)) {   // bool or _Bool
						colType = @"INTEGER";
                    } else if (isSqliteRealType(propTypeChar)) {  // double
						colType = @"REAL";
                    }
                    NSString *alterSQL = [NSString stringWithFormat:@"alter table %@ add column %@ %@", [self tableName], propName, colType];
					[db executeUpdate:alterSQL];
				}
			}
			
		}
	}
}
- (void)setPk:(int)newPk
{
	pk = newPk;
}
#pragma mark -
#pragma mark KV
- (void)takeValuesFromDictionary:(NSDictionary *)properties
{
	[self markDirty];
	[super takeValuesFromDictionary:properties];
}
- (void)takeValue:(id)value forKey:(NSString *)key
{
	[self markDirty];
	[super takeValue:value forKey:key];
}
- (void)setValue:(id)value forKey:(NSString *)key
{
	[self markDirty];
	[super setValue:value forKey:key];
}
#pragma mark -
#pragma mark Memory Map Methods
+ (NSString *)memoryMapKeyForObject:(NSInteger)thePK
{
	return [NSString stringWithFormat:@"%@-%d", [self className], thePK];
}
- (NSString *)memoryMapKey
{
	return [[self class] memoryMapKeyForObject:[self pk]];
}
+ (void)registerObjectInMemory:(SQLitePersistentObject *)theObject
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        objectMap = [[NSMutableDictionary alloc] init];
    });
    @synchronized(objectMap) {
        [objectMap setObject:theObject forKey:[theObject memoryMapKey]];
    }
}
+ (void)unregisterObject:(SQLitePersistentObject *)theObject
{
    @synchronized(objectMap) {
        if (objectMap == nil)
            objectMap = [[NSMutableDictionary alloc] init];
	}
    @synchronized(objectMap) {
        // We have to make sure we're not removing objects from memory map when deleting partially created ones...
        SQLitePersistentObject *compare = [objectMap objectForKey:[theObject memoryMapKey]];
        if (compare == theObject) {
            [objectMap removeObjectForKey:[theObject memoryMapKey]];
        }
    }
}
@end


static BOOL isSqliteIntegerType(char propType)
{
    static char set[] = "BILQSilqs";
    char *result = bsearch(&propType, &set[0], strlen(set), sizeof(char), &cmpAscending);
    return result != NULL;
}

static BOOL isSqliteSignedIntegerOrBooleanType(char propType)
{
    static char set[] = "Bilqs";
    char *result = bsearch(&propType, set, strlen(set), sizeof(char), &cmpAscending);
    return result != NULL;
}

static BOOL isSqliteUnsignedIntegerType(char propType) {
    static char set[] = "ILQS";
    char *result = bsearch(&propType, set, strlen(set), sizeof(char), &cmpAscending);
    return result != NULL;
}

static BOOL isSqliteRealType(char propType)
{
    return propType == 'f' || propType == 'd';
}

static BOOL isSqliteCharType(char propType) {
    return propType == 'c' || propType == 'C';
}

static BOOL isScalarType(char propType) {
    static char set[] = "BCILQScdfilqs";
    qsort(set, strlen(set), sizeof(char), &cmpAscending);
    char *result = bsearch(&propType, set, strlen(set), sizeof(char), &cmpAscending);
    return result != NULL;
}