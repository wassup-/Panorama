//
//  PanoramaView.m
//  Panorama
//
//  Created by Robby Kraft on 8/24/13.
//  Copyright (c)2013 Robby Kraft. All rights reserved.
//

#import "PanoramaView.h"
#import "PanoramaSphere.h"

@import CoreMotion;

#import <OpenGLES/ES1/gl.h>


#define FOV_MIN 1
#define FOV_MAX 155
#define Z_NEAR 0.1f
#define Z_FAR 100.f

static GLfloat fclamp(GLfloat val, GLfloat min, GLfloat max) {
    return MAX(min, MIN(val, max));
}

typedef NS_ENUM(NSUInteger, SensorOrientation) {
    SensorOrientationUnknown = 0,
    SensorOrientationNorth,
    SensorOrientationEast,
    SensorOrientationSouth,
    SensorOrientationWest,
};

SensorOrientation GetSensorOrientation() {
    switch(UIApplication.sharedApplication.statusBarOrientation) {
        case UIInterfaceOrientationPortrait: {
            return SensorOrientationNorth;
        }
        case UIInterfaceOrientationLandscapeLeft: {
            return SensorOrientationEast;
        }
        case UIInterfaceOrientationLandscapeRight: {
            return SensorOrientationSouth;
        }
        case UIInterfaceOrientationPortraitUpsideDown: {
            return SensorOrientationWest;
        }
        // case UIInterfaceOrientationUnknown:
        default: {
            return SensorOrientationUnknown;
        }
    }
}

// this really should be included in GLKit
GLKQuaternion GLKQuaternionFromTwoVectors(GLKVector3 u, GLKVector3 v) {
    GLKVector3 w = GLKVector3CrossProduct(u, v);
    GLKQuaternion q = GLKQuaternionMake(w.x, w.y, w.z, GLKVector3DotProduct(u, v));
    q.w += GLKQuaternionLength(q);
    return GLKQuaternionNormalize(q);
}

@interface PanoramaView () {
    GLfloat circlePoints[64 * 3];  // meridian lines
}

@property (strong, nonatomic) CMMotionManager *motionManager;
@property (strong, nonatomic) PanoramaSphere *sphere;
@property (strong, nonatomic) UIPinchGestureRecognizer *pinchGesture;
@property (strong, nonatomic) UIPanGestureRecognizer *panGesture;

@property (assign, nonatomic) GLKMatrix4 projectionMatrix;
@property (assign, nonatomic) GLKMatrix4 attitudeMatrix;
@property (assign, nonatomic) GLKMatrix4 offsetMatrix;

@property (assign, nonatomic) GLfloat aspectRatio;

@end

@implementation PanoramaView

-(instancetype)init {
	self = [super init];
//	[self commonInit];
	return self;
}

-(instancetype)initWithCoder:(NSCoder *)aDecoder {
	self = [super initWithCoder:aDecoder];
	[self commonInit];
	return self;
}

-(instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if(CGRectIsEmpty(frame)) {
		frame = UIScreen.mainScreen.bounds;
	}
	[self commonInit:frame];
	return self;
}

-(id)initWithFrame:(CGRect)frame context:(EAGLContext *)context {
    self = [super initWithFrame:frame context:context];
	[self commonInit:frame context:context];
    return self;
}

-(void)commonInit {
	const CGRect frame = UIScreen.mainScreen.bounds;
	[self commonInit:frame];
}

-(void)commonInit:(CGRect)frame {
	EAGLContext *const context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
	[EAGLContext setCurrentContext:context];
	self.context = context;
	[self commonInit:frame context:context];
}

-(void)commonInit:(CGRect)frame context:(EAGLContext *)context {
	[self initDevice];
	[self initOpenGL:context];
	self.sphere = [[PanoramaSphere alloc] init:48 slices:48 radius:10.0 textureFile:nil];
}

-(void)initDevice {
    self.motionManager = [CMMotionManager new];

    self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget: self
                                                                  action: @selector(pinchHandler:)];
    self.pinchGesture.enabled = NO;
    [self addGestureRecognizer:self.pinchGesture];

    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget: self
                                                              action: @selector(panHandler:)];
    self.panGesture.maximumNumberOfTouches = 1;
    self.panGesture.enabled = NO;
    [self addGestureRecognizer:self.panGesture];
}

#pragma mark - PROPERTIES

-(void)setFieldOfView:(float)fieldOfView {
	_fieldOfView = fieldOfView;
	[self rebuildProjectionMatrix];
}

-(void)setImage:(UIImage*)image {
	[self.sphere swapTextureWithImage:image];
}

-(void)setImageByFilename:(NSString *)fileName {
	[self.sphere swapTexture:fileName];
}

-(BOOL)touchToPan {
    return self.panGesture.enabled;
}

-(void)setTouchToPan:(BOOL)touchToPan {
    self.panGesture.enabled = touchToPan;
}

-(BOOL)pinchToZoom {
    return self.pinchGesture.enabled;
}

-(void)setPinchToZoom:(BOOL)pinchToZoom {
    self.pinchGesture.enabled = pinchToZoom;
}

-(void)setOrientToDevice:(BOOL)orientToDevice {
    _orientToDevice = orientToDevice;
    if(self.motionManager.isDeviceMotionAvailable) {
        if(_orientToDevice) {
            [self.motionManager startDeviceMotionUpdates];
        } else {
            [self.motionManager stopDeviceMotionUpdates];
        }
    }
}

#pragma mark- OPENGL

-(void)initOpenGL:(EAGLContext*)context {
    [(CAEAGLLayer *)self.layer setOpaque:NO];
    self.aspectRatio = CGRectGetWidth(self.frame) / CGRectGetHeight(self.frame);
    self.fieldOfView = 45 + 45 * atanf(self.aspectRatio); // hell ya
    [self rebuildProjectionMatrix];

    self.attitudeMatrix = GLKMatrix4Identity;
    self.offsetMatrix = GLKMatrix4Identity;
    [self customGL];
    [self makeLatitudeLines];
}

-(void)rebuildProjectionMatrix {
    const GLfloat frustum = Z_NEAR * tanf(self.fieldOfView * 0.00872664625997);  // pi/180/2

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    _projectionMatrix = GLKMatrix4MakeFrustum(-frustum, frustum, -frustum / self.aspectRatio, frustum / self.aspectRatio, Z_NEAR, Z_FAR);
    glMultMatrixf(_projectionMatrix.m);
    glViewport(0, 0, CGRectGetWidth(self.frame), CGRectGetHeight(self.frame));
    glMatrixMode(GL_MODELVIEW);
}

-(void)customGL {
    glMatrixMode(GL_MODELVIEW);
    //    glEnable(GL_CULL_FACE);
    //    glCullFace(GL_FRONT);
    //    glEnable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

-(void)display {
    [super display];

    static GLfloat const whiteColor[] = {1.0f, 1.0f, 1.0f, 1.0f};
    static GLfloat const clearColor[] = {0.7f, 0.7f, 0.7f, 1.0f};
	static GLfloat const touchColor[] = {1.0f, 0.0f, 0.0f, 0.7f};

    glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
    glClear(GL_COLOR_BUFFER_BIT);
    glPushMatrix(); // begin device orientation

    self.attitudeMatrix = GLKMatrix4Multiply([self getDeviceOrientationMatrix], self.offsetMatrix);
    [self updateLook];

    glMultMatrixf(self.attitudeMatrix.m);

    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, whiteColor);  // panorama at full color
    [self.sphere render];
    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, clearColor);
    //        [meridians render];  // semi-transparent texture overlay (15° meridian lines)

    //TODO: add any objects here to make them a part of the virtual reality
    //        glPushMatrix();
    //        // object code
    //        glPopMatrix();

    // touch lines
    if(_showTouches && _numberOfTouches) {
		glColor4f(touchColor[0], touchColor[1], touchColor[2], touchColor[3]);
        for(unsigned i = 0; i < _touches.allObjects.count; i++) {
            UITouch *const touch = (UITouch*)[_touches.allObjects objectAtIndex:i];
            CGPoint touchPoint = [touch locationInView:self];

            glPushMatrix();
            [self drawHotspotLines:[self vectorFromScreenLocation:touchPoint inAttitude:self.attitudeMatrix]];
            glPopMatrix();
        }
        glColor4f(whiteColor[0], whiteColor[1], whiteColor[2], whiteColor[3]);
    }

    glPopMatrix(); // end device orientation
}

#pragma mark- ORIENTATION

-(GLKMatrix4)getDeviceOrientationMatrix {
    if(_orientToDevice && [self.motionManager isDeviceMotionActive]) {
        const CMRotationMatrix a = [[self.motionManager.deviceMotion attitude] rotationMatrix];
        // arrangements of mappings of sensor axis to virtual axis (columns)
        // and combinations of 90 degree rotations (rows)
        switch(GetSensorOrientation()) {
            case SensorOrientationWest: {
                return GLKMatrix4Make( a.m21, -a.m11,  a.m31, 0.f,
                                      a.m23, -a.m13,  a.m33, 0.f,
                                      -a.m22,  a.m12, -a.m32, 0.f,
                                      0.f,    0.f,    0.f, 1.f);
            }
            case SensorOrientationSouth: {
                return GLKMatrix4Make(-a.m21,  a.m11,  a.m31, 0.f,
                                      -a.m23,  a.m13,  a.m33, 0.f,
                                      a.m22, -a.m12, -a.m32, 0.f,
                                      0.f,    0.f,    0.f, 1.f);
            }
            case SensorOrientationEast: {
                return GLKMatrix4Make(-a.m11, -a.m21,  a.m31, 0.f,
                                      -a.m13, -a.m23,  a.m33, 0.f,
                                      a.m12,  a.m22, -a.m32, 0.f,
                                      0.f,    0.f,    0.f, 1.f);
            }
            case SensorOrientationNorth:
            default: {
                return GLKMatrix4Make( a.m11,  a.m21,  a.m31, 0.f,
                                      a.m13,  a.m23,  a.m33, 0.f,
                                      -a.m12, -a.m22, -a.m32, 0.f,
                                      0.f,    0.f,    0.f, 1.f);
            }
        }
    } else {
        return GLKMatrix4Identity;
    }
}

-(void)orientToVector:(GLKVector3)v {
    self.attitudeMatrix = GLKMatrix4MakeLookAt(  0,   0,   0,
                                           v.x, v.y, v.z,
                                           0,   1,   0);
    [self updateLook];
}

-(void)orientToAzimuth:(float)azimuth Altitude:(float)altitude {
    [self orientToVector:GLKVector3Make(-cosf(azimuth), sinf(altitude), sinf(azimuth))];
}

-(void)updateLook {
    _lookVector = GLKVector3Make(-self.attitudeMatrix.m02,
                                 -self.attitudeMatrix.m12,
                                 -self.attitudeMatrix.m22);
    _lookAzimuth = atan2f(_lookVector.x, -_lookVector.z);
    _lookAltitude = asinf(_lookVector.y);
}

-(CGPoint)imagePixelAtScreenLocation:(CGPoint)point {
    return [self imagePixelFromVector:[self vectorFromScreenLocation:point inAttitude:self.attitudeMatrix]];
}

-(CGPoint)imagePixelFromVector:(GLKVector3)vector {
    return [self.sphere imagePixelFromVector:vector];
}

-(GLKVector3)vectorFromScreenLocation:(CGPoint)point {
    return [self vectorFromScreenLocation:point inAttitude:self.attitudeMatrix];
}

-(GLKVector3)vectorFromScreenLocation:(CGPoint)point inAttitude:(GLKMatrix4)matrix {
    const GLKMatrix4 inverse = GLKMatrix4Invert(GLKMatrix4Multiply(_projectionMatrix, matrix), nil);
    const GLKVector4 screen = GLKVector4Make(2.0 * (point.x / CGRectGetWidth(self.frame) - .5),
                                       2.0 * (.5 - point.y / CGRectGetHeight(self.frame)),
                                       1.0, 1.0);
    const GLKVector4 vec = GLKMatrix4MultiplyVector4(inverse, screen);
    return GLKVector3Normalize(GLKVector3Make(vec.x, vec.y, vec.z));
}

-(CGPoint)screenLocationFromVector:(GLKVector3)vector {
    const GLKMatrix4 matrix = GLKMatrix4Multiply(_projectionMatrix, self.attitudeMatrix);
    const GLKVector3 screenVector = GLKMatrix4MultiplyVector3(matrix, vector);
    return CGPointMake((screenVector.x / screenVector.z / 2.0 + 0.5) * CGRectGetWidth(self.frame),
                       (0.5 - screenVector.y / screenVector.z / 2) * CGRectGetHeight(self.frame));
}

-(BOOL)computeScreenLocation:(CGPoint*)location fromVector:(GLKVector3)vector inAttitude:(GLKMatrix4)matrix {
    //This method returns whether the point is before or behind the screen.
    if(location == NULL) {
        return NO;
    }
    matrix = GLKMatrix4Multiply(_projectionMatrix, matrix);
    const GLKVector4 vector4 = GLKVector4Make(vector.x, vector.y, vector.z, 1);
    const GLKVector4 screenVector = GLKMatrix4MultiplyVector4(matrix, vector4);
    location->x = (screenVector.x / screenVector.w / 2.0 + 0.5) * CGRectGetWidth(self.frame);
    location->y = (0.5-screenVector.y / screenVector.w / 2) * CGRectGetHeight(self.frame);
    return (screenVector.z >= 0);
}

#pragma mark- TOUCHES

-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    _touches = event.allTouches;
    _numberOfTouches = event.allTouches.count;
}

-(void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    _touches = event.allTouches;
    _numberOfTouches = event.allTouches.count;
}

-(void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    _touches = event.allTouches;
    _numberOfTouches = 0;
}

-(BOOL)touchInRect:(CGRect)rect {
    if(_numberOfTouches) {
        for(int i = 0; i < [_touches.allObjects count]; i++) {
            UITouch *const touch = (UITouch *)[_touches.allObjects objectAtIndex:i];
            CGPoint touchPoint = [touch locationInView: self];
            if(CGRectContainsPoint(rect, [self imagePixelAtScreenLocation:touchPoint])) {
                return true;
            }
        }
    }
    return false;
}

-(void)pinchHandler:(UIPinchGestureRecognizer*)sender {
    _numberOfTouches = sender.numberOfTouches;
    static float zoom;
    switch(sender.state) {
        case UIGestureRecognizerStateBegan: {
            zoom = self.fieldOfView;
        }
        case UIGestureRecognizerStateChanged: {
            const CGFloat fov = fclamp(zoom / sender.scale, FOV_MIN, FOV_MAX);
            [self setFieldOfView:fov];
        }
        case UIGestureRecognizerStateEnded: {
            _numberOfTouches = 0;
        }
    }
}

-(void)panHandler:(UIPanGestureRecognizer*)sender {
    static GLKVector3 touchVector;
    switch(sender.state) {
        case UIGestureRecognizerStateBegan: {
            touchVector = [self vectorFromScreenLocation: [sender locationInView:sender.view]
                                              inAttitude: self.offsetMatrix];
        }
        case UIGestureRecognizerStateChanged: {
            GLKVector3 nowVector = [self vectorFromScreenLocation: [sender locationInView:sender.view]
                                                       inAttitude: self.offsetMatrix];
            GLKQuaternion q = GLKQuaternionFromTwoVectors(touchVector, nowVector);
            self.offsetMatrix = GLKMatrix4Multiply(self.offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
            // in progress for preventHeadTilt
            //        GLKMatrix4 mat = GLKMatrix4Multiply(self.offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
            //        self.offsetMatrix = GLKMatrix4MakeLookAt(0, 0, 0, -mat.m02, -mat.m12, -mat.m22,  0, 1, 0);
        }
        default: {
            _numberOfTouches = 0;
        }
    }
}

#pragma mark- MERIDIANS

-(void)makeLatitudeLines {
    for(int i = 0; i < 64; i++) {
        circlePoints[(i * 3) + 0] = -sinf(M_PI * 2 / 64.0f * i);
        circlePoints[(i * 3) + 1] = 0.f;
        circlePoints[(i * 3) + 2] = cosf(M_PI * 2 / 64.0f * i);
    }
}

-(void)drawHotspotLines:(GLKVector3)touchLocation {
    const GLfloat scale = sqrtf(1 - powf(touchLocation.y, 2));

    glLineWidth(2.0f);

    glPushMatrix();
    glScalef(scale, 1.f, scale);
    glTranslatef(0, touchLocation.y, 0);
    glDisableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, circlePoints);
    glDrawArrays(GL_LINE_LOOP, 0, 64);
    glDisableClientState(GL_VERTEX_ARRAY);
    glPopMatrix();

    glPushMatrix();
    glRotatef(-atan2f(-touchLocation.z, -touchLocation.x) * 180 / M_PI, 0, 1, 0);
    glRotatef(90, 1, 0, 0);
    glDisableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, circlePoints);
    glDrawArrays(GL_LINE_STRIP, 0, 33);
    glDisableClientState(GL_VERTEX_ARRAY);
    glPopMatrix();
}

@end
