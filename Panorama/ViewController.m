//
//  ViewController.m
//  Panorama
//
//  Created by Robby Kraft on 8/24/13.
//  Copyright (c) 2013 Robby Kraft. All Rights Reserved.
//

#import "ViewController.h"
#import "PanoramaView.h"

@interface ViewController (){
    PanoramaView *panoramaView;
}
@end

@implementation ViewController

- (void)viewDidLoad{
    [super viewDidLoad];
	
	self.preferredFramesPerSecond = 60;
	
    panoramaView = [PanoramaView new];
    [panoramaView setImageByFilename:@"pano.png"];
    [panoramaView setOrientToDevice:YES];
    [panoramaView setTouchToPan:NO];
    [panoramaView setPinchToZoom:YES];
    [panoramaView setShowTouches:YES];
    [self setView:panoramaView];
}

-(void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.paused = NO;
}

-(void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	self.paused = YES;
}

@end
