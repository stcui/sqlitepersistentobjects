//
//  Collections.h
//  SQLiteTests
//
//  Created by al on 16/01/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SQLitePersistentObject.h"
//#import "SQLiteMutableArray.h"

@interface Collections : SQLitePersistentObject
{		
	NSMutableArray*			stringsArray;
	NSMutableDictionary*	stringsDict;
	NSMutableSet*			stringsSet;
	
	NSMutableArray*			dataArray;
	NSMutableDictionary*	dataDict;
	NSMutableSet*			dataSet;	
}

@property(strong) NSMutableArray* stringsArray;
@property(strong) NSMutableDictionary* stringsDict;
@property(strong) NSMutableSet* stringsSet;

@property(strong) NSMutableArray* dataArray;
@property(strong) NSMutableDictionary* dataDict;
@property(strong) NSMutableSet* dataSet;

-(void) setFixtureData;

@end