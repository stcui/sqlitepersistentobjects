//
//  TestRelationship.m
//  SQLiteTests
//
//  Created by stcui on 13-7-16.
//
//

#import "GTMSenTestCase.h"
#import "SQLitePersistentObject.h"
#import "SQLiteInstanceManager.h"
#import "NSString-SQLiteColumnName.h"
#import "Collections.h"
#import "NSDataContainer.h"
#import "RecursiveReferential.h"

@interface TestRelationship : SenTestCase
{
	SQLiteInstanceManager* _manager;
}
@end

@implementation TestRelationship
-(id) init
{
	_manager = [SQLiteInstanceManager sharedManager];
	[_manager deleteDatabase];
	return self;
}

- (void)setUp
{
	NSLog(@"Database located at: %@", _manager.databaseFilepath);
}

- (void)tearDown
{
	[_manager deleteDatabase];
}

- (void)testSaveAndLoad
{
    NSDataContainer *container = [[NSDataContainer alloc] init];
    [container setFixtureDataWithOutRelation];
    [container save];
    [SQLitePersistentObject clearCache];

    NSDataContainer *loadContainer = [[NSDataContainer allObjects] lastObject];
    [loadContainer setFixtureData];
    [loadContainer save];
    [SQLitePersistentObject clearCache];
    
    loadContainer = [[NSDataContainer allObjects] lastObject];
    STAssertTrue(loadContainer.basicObjects.count == 100, @"basic objects load error");
}
@end
