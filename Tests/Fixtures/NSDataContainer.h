//
//  NSDataContainer.h
//  SQLiteTests
//
//  Created by al on 16/01/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SQLitePersistentObject.h"
#import "BasicData.h"

@interface NSDataContainer : SQLitePersistentObject
{		
	unsigned	unsignedArray[100];
	NSData*		unsignedArrayData;
	
	CGRect		rect;
	NSData*		rectData;
	
	NSNumber*	number;
	NSNumber*	transientNumber;
	NSDate*		date;
	BasicData*	basic;
}

@property(strong) NSData* unsignedArrayData;
@property(strong) NSData* rectData;
@property(strong) NSNumber* number;
@property(strong) NSNumber* transientNumber;
@property(strong) NSDate* date;
@property(strong) BasicData* basic;
@property(strong, nonatomic) NSArray *basicObjects;
-(void) setFixtureData;
- (void)setFixtureDataWithOutRelation;
@end
