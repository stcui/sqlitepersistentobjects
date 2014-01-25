//
//  Collections.m
//  SQLiteTests
//
//  Created by al on 16/01/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "Collections.h"


@implementation Collections

@synthesize stringsArray,stringsDict,stringsSet,dataArray,dataDict,dataSet;

-(id) init
{
	if (self = [super init]) {
        stringsArray = [[NSMutableArray alloc] init];
        stringsDict = [[NSMutableDictionary alloc] init];
        stringsSet = [[NSMutableSet alloc] init];
        
        dataArray = [[NSMutableArray alloc] init];
        dataDict = [[NSMutableDictionary alloc] init];
        dataSet = [[NSMutableSet alloc] init];
    }
	return self;
}

- (void)dealloc
{
    self.stringsArray = nil;
    self.stringsDict = nil;
    self.stringsSet = nil;
    self.dataArray = nil;
    self.dataDict = nil;
    self.dataSet = nil;
    [super dealloc];
}

-(void) setFixtureData
{
	char buffer[128];
	
	for (int i=0; i<100; i++) 
	{
		sprintf(buffer, "%d", (rand() % 9999) );
		NSString* string = [NSString stringWithUTF8String:buffer];
		
		[self.stringsArray addObject:string];
		[self.stringsDict setObject:string forKey:[string copy]];
		[self.stringsSet addObject:string];
		
		
		NSData* data = [NSData dataWithBytes:buffer length: sizeof(char)*128];
		[self.dataArray addObject:data];
		[self.dataDict setObject:data forKey:string];
		[self.dataSet addObject:data];		
	}
}

@end