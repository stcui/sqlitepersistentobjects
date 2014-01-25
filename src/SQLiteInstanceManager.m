//
//  SQLiteInstanceManager.m
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

#import <TargetConditionals.h>

#import "SQLiteInstanceManager.h"
#import "SQLitePersistentObject.h"


#pragma mark Private Method Declarations
@interface SQLiteInstanceManager (private)
- (NSString *)databaseFilepath;
@end

@implementation SQLiteInstanceManager
{
    NSArray *queues;
    NSMutableArray *opCount;
}
@synthesize databaseFilepath;

#pragma mark -
#pragma mark Singleton Methods
+ (id)sharedManager 
{
    static SQLiteInstanceManager *sharedSQLiteManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedSQLiteManager = [[self alloc] init];
    });
	
	return sharedSQLiteManager;
}

- (id)init
{
    self = [super init];
    if (self) {
    }
    return self;
}
#pragma mark -
#pragma mark Public Instance Methods
-(void)pragmasOnOpen {
    // Default to UTF-8 encoding
    [self executeUpdateSQL:@"PRAGMA encoding = \"UTF-8\""];

    // Turn on full auto-vacuuming to keep the size of the database down
    // This setting can be changed per database using the setAutoVacuum instance method
    [self executeUpdateSQL:@"PRAGMA auto_vacuum=1"];

    // Set cache size to zero. This will prevent performance slowdowns as the
    // database gets larger
    [self executeUpdateSQL:@"PRAGMA CACHE_SIZE=0"];
}

- (BOOL)rekey:(NSString*)key {
#ifdef SQLITE_HAS_CODEC
    if (!key) {
        return NO;
    }
    BOOL result = [[self db] rekey:key];

    return result;
#else
    return NO;
#endif
}

-(BOOL)setKey:(NSString *)key {
#ifdef SQLITE_HAS_CODEC
    if (!key) {
        return NO;
    }
    BOOL result = [[self db] setKey:key];
    [self pragmasOnOpen];
    return result;
#else
    return NO;
#endif
}

- (FMDatabase *)db
{
    @synchronized(self) {
        if (!_db) {
            _db = [[FMDatabase alloc] initWithPath:self.databaseFilepath];
            [_db open];

            // Default to UTF-8 encoding
            [_db executeUpdate:@"PRAGMA encoding = \"UTF-8\""];
            
            // Turn on full auto-vacuuming to keep the size of the database down
            // This setting can be changed per database using the setAutoVacuum instance method
            [_db executeUpdate:@"PRAGMA auto_vacuum=1"];
            
            // Set cache size to zero. This will prevent performance slowdowns as the
            // database gets larger
            [_db executeUpdate:@"PRAGMA CACHE_SIZE=0"];
        }
        return _db;
    }
}

- (FMDatabaseQueue *)queryQueue
{
    @synchronized(self) {
        if (nil == _queryQueue) {
            [self db];
            _queryQueue = [[FMDatabaseQueue alloc] initWithPath:self.databaseFilepath];
        }
    }
    return _queryQueue;
}

- (FMDatabaseQueue *)saveQueue
{
    @synchronized(self) {
        if (nil == _saveQueue) {
            [self db];
            _saveQueue = [[FMDatabaseQueue alloc] initWithPath:self.databaseFilepath];
        }
    }
    return _saveQueue;
}
- (BOOL)tableExists:(NSString *)tableName
{
	// pragma table_info(i_c_project);
    NSString *query = [NSString stringWithFormat:@"pragma table_info(%@);", tableName];
    __block BOOL hasData;
    [[self queryQueue] inDatabase:^(FMDatabase *db) {
       FMResultSet *result = [db executeQuery:query];
        hasData = result.next;
        [result close];
    }];
    return hasData;
}

- (void)setAutoVacuum:(SQLITE3AutoVacuum)mode
{
	NSString *updateSQL = [NSString stringWithFormat:@"PRAGMA auto_vacuum=%d", mode];
	[self executeUpdateSQL:updateSQL];
}
- (void)setCacheSize:(NSUInteger)pages
{
	NSString *updateSQL = [NSString stringWithFormat:@"PRAGMA cache_size=%ld", (unsigned long)pages];
	[self executeUpdateSQL:updateSQL];
}
- (void)setLockingMode:(SQLITE3LockingMode)mode
{
	NSString *updateSQL = [NSString stringWithFormat:@"PRAGMA locking_mode=%d", mode];
	[self executeUpdateSQL:updateSQL];
}
- (void)deleteDatabase
{
	NSString* path = [self databaseFilepath];
	NSFileManager* fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:path error:NULL];
    [_saveQueue close];
    [_queryQueue close];
    [_db close];
    _db = nil;
    _saveQueue = nil;
    _queryQueue = nil;
	[SQLitePersistentObject clearCache];
}
- (void)vacuum
{
	[self executeUpdateSQL:@"VACUUM"];
}
- (void)executeUpdateSQL:(NSString *) updateSQL
{
    if (![self.db executeUpdate:updateSQL]) {
		NSLog(@"Failed to execute SQL '%@' with message '%@'.", updateSQL, self.db.lastError);
	}
}
- (void)executeQuery:(NSString *)querySQL completion:(void(^)(FMResultSet *resultSet))completion
{
    [self.queryQueue inDatabase:^(FMDatabase *db) {
        FMResultSet *result = [db executeQuery:querySQL];
        if (completion) completion(result);
        [result close];
    }];
}

#pragma mark -
#pragma mark Private Methods

- (NSString *)databaseFilepath
{
	if (databaseFilepath == nil)
	{
		NSMutableString *ret = [NSMutableString string];
		NSString *appName = [[NSProcessInfo processInfo] processName];
		for (int i = 0; i < [appName length]; i++)
		{
			NSRange range = NSMakeRange(i, 1);
			NSString *oneChar = [appName substringWithRange:range];
			if (![oneChar isEqualToString:@" "]) 
				[ret appendString:[oneChar lowercaseString]];
		}
#if (TARGET_OS_COCOTRON)
		NSString *saveDirectory = @"./"; // TODO: default path is undefined on coctron
#elif (TARGET_OS_MAC && ! TARGET_OS_IPHONE)
		NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
		NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
		NSString *saveDirectory = [basePath stringByAppendingPathComponent:appName];
#else
		NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
		NSString *saveDirectory = [paths objectAtIndex:0];
#endif
		NSString *saveFileName = [NSString stringWithFormat:@"%@.sqlite3", ret];
		NSString *filepath = [saveDirectory stringByAppendingPathComponent:saveFileName];
		
		databaseFilepath = filepath;
		
		if (![[NSFileManager defaultManager] fileExistsAtPath:saveDirectory]) 
			[[NSFileManager defaultManager] createDirectoryAtPath:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
	}
	return databaseFilepath;
}
@end

@implementation FMResultSet (ArrayExt)
- (NSArray *)toArray
{
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:16];
    while (self.next) {
        [array addObject:self.resultDictionary];
    }
    [self close];
    return array;
}
@end
