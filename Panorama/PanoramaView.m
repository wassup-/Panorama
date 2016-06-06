//
//  PanoramaView.m
//  Panorama
//
//  Created by Robby Kraft on 8/24/13.
//  Copyright (c)2013 Robby Kraft. All rights reserved.
//

#import <CoreMotion/CoreMotion.h>
#import <OpenGLES/ES1/gl.h>
#import <GLKit/GLKit.h>
#import "PanoramaView.h"

#define FOV_MIN 1
#define FOV_MAX 155
#define Z_NEAR 0.1f
#define Z_FAR 100.f

static GLfloat fclamp(GLfloat val, GLfloat min, GLfloat max) {
    return MAX(min, MIN(val, max));
}

// LINEAR for smoothing, NEAREST for pixelized
#define IMAGE_SCALING GL_LINEAR  // GL_NEAREST, GL_LINEAR

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
    const GLKVector3 w = GLKVector3CrossProduct(u, v);
    GLKQuaternion q = GLKQuaternionMake(w.x, w.y, w.z, GLKVector3DotProduct(u, v));
    q.w += GLKQuaternionLength(q);
    return GLKQuaternionNormalize(q);
}

@interface Sphere : NSObject

-(bool)execute;
-(id)init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile;
-(void)swapTexture:(NSString*)textureFile;
-(void)swapTextureWithImage:(UIImage*)image;
-(CGPoint)getTextureSize;

@end

@interface PanoramaView () {
    Sphere *sphere/*, *meridians*/;
    CMMotionManager *motionManager;
    UIPinchGestureRecognizer *pinchGesture;
    UIPanGestureRecognizer *panGesture;
    GLKMatrix4 _projectionMatrix, _attitudeMatrix, _offsetMatrix;
    float _aspectRatio;
    GLfloat circlePoints[64 * 3];  // meridian lines
}
@end

@implementation PanoramaView

-(void)commonInit {
    CGRect frame = UIScreen.mainScreen.bounds;
    [self commonInit:frame];
}

-(void)commonInit:(CGRect)frame {
    EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:context];
    self.context = context;
    [self commonInit:frame context:context];
}

-(void)commonInit:(CGRect)frame context:(EAGLContext *)context {
    [self initDevice];
    [self initOpenGL:context];
    sphere = [[Sphere alloc] init:48 slices:48 radius:10.0 textureFile:nil];
    //  meridians = [[Sphere alloc] init:48 slices:48 radius:8.0 textureFile:@"equirectangular-projection-lines.png"];
}

-(id)init {
    self = [super init];
    [self commonInit];
    return self;
}

-(id)initWithCoder:(NSCoder *)aCoder {
    self = [super initWithCoder:aCoder];
    [self commonInit];
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    [self commonInit:frame];
    return self;
}

-(id)initWithFrame:(CGRect)frame context:(EAGLContext *)context {
    self = [super initWithFrame:frame];
    [self commonInit:frame context:context];
    return self;
}

-(void)didMoveToSuperview {
    // this breaks MVC, but useful for setting GLKViewController's frame rate
    UIResponder *responder = self;
    while (![responder isKindOfClass:GLKViewController.class]) {
        responder = responder.nextResponder;
        if (responder == nil) {
            break;
        }
    }
}

-(void)initDevice {
    motionManager = [CMMotionManager new];
    pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchHandler:)];
    pinchGesture.enabled = NO;
    [self addGestureRecognizer:pinchGesture];

    panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panHandler:)];
    [panGesture setMaximumNumberOfTouches:1];
    panGesture.enabled = NO;
    [self addGestureRecognizer:panGesture];
}

-(void)setFieldOfView:(float)fieldOfView {
    _fieldOfView = fieldOfView;
    [self rebuildProjectionMatrix];
}

-(void)setImage:(UIImage*)image {
    [sphere swapTextureWithImage:image];
}

-(void)setImageByFilename:(NSString *)fileName {
    [sphere swapTexture:fileName];
}

-(void)setTouchToPan:(BOOL)touchToPan {
    _touchToPan = touchToPan;
    panGesture.enabled =_touchToPan;
}

-(void)setPinchToZoom:(BOOL)pinchToZoom {
    _pinchToZoom = pinchToZoom;
    pinchGesture.enabled = _pinchToZoom;
}

-(void)setOrientToDevice:(BOOL)orientToDevice {
    _orientToDevice = orientToDevice;
    if(motionManager.isDeviceMotionAvailable) {
        if(_orientToDevice) {
            [motionManager startDeviceMotionUpdates];
        } else {
            [motionManager stopDeviceMotionUpdates];
        }
    }
}

#pragma mark- OPENGL

-(void)initOpenGL:(EAGLContext*)context {
    [(CAEAGLLayer*)self.layer setOpaque:NO];
    _aspectRatio = CGRectGetWidth(self.frame) / CGRectGetHeight(self.frame);
    _fieldOfView = 45 + 45 * atanf(_aspectRatio); // hell ya
    [self rebuildProjectionMatrix];
    _attitudeMatrix = GLKMatrix4Identity;
    _offsetMatrix = GLKMatrix4Identity;
    [self customGL];
    [self makeLatitudeLines];
}

-(void)rebuildProjectionMatrix {
    const GLfloat frustum = Z_NEAR * tanf(_fieldOfView * 0.00872664625997);  // pi/180/2

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    _projectionMatrix = GLKMatrix4MakeFrustum(-frustum, frustum, -frustum / _aspectRatio, frustum / _aspectRatio, Z_NEAR, Z_FAR);
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
    [self draw];
}

-(void)draw {
    static GLfloat const whiteColor[] = {1.f, 1.f, 1.f, 1.f};
    static GLfloat const clearColor[] = {.7f, .7f, .7f, 1.f};
	static GLfloat const touchColor[] = {1.f, 0.f, 0.f, .6f};

    glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
    glClear(GL_COLOR_BUFFER_BIT);
    glPushMatrix(); // begin device orientation

    _attitudeMatrix = GLKMatrix4Multiply([self getDeviceOrientationMatrix], _offsetMatrix);
    [self updateLook];

    glMultMatrixf(_attitudeMatrix.m);

    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, whiteColor);  // panorama at full color
    [sphere execute];
    glMaterialfv(GL_FRONT_AND_BACK, GL_EMISSION, clearColor);
    //        [meridians execute];  // semi-transparent texture overlay (15° meridian lines)

    //TODO: add any objects here to make them a part of the virtual reality
    //        glPushMatrix();
    //        // object code
    //        glPopMatrix();

    // touch lines
    if(_showTouches && _numberOfTouches) {
		glColor4f(touchColor[0], touchColor[1], touchColor[2], touchColor[3]);
        for(int i = 0; i < _touches.allObjects.count; i++) {
            UITouch *const touch = (UITouch*)[_touches.allObjects objectAtIndex:i];
            CGPoint touchPoint = [touch locationInView:self];

            glPushMatrix();
            [self drawHotspotLines:[self vectorFromScreenLocation:touchPoint inAttitude:_attitudeMatrix]];
            glPopMatrix();
        }
		glColor4f(whiteColor[0], whiteColor[1], whiteColor[2], whiteColor[3]);
    }

    glPopMatrix(); // end device orientation
}

#pragma mark- ORIENTATION

-(GLKMatrix4)getDeviceOrientationMatrix {
    if(_orientToDevice && [motionManager isDeviceMotionActive]) {
        const CMRotationMatrix a = [[motionManager.deviceMotion attitude] rotationMatrix];
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
    _attitudeMatrix = GLKMatrix4MakeLookAt(  0,   0,   0,
                                           v.x, v.y, v.z,
                                           0,   1,   0);
    [self updateLook];
}

-(void)orientToAzimuth:(float)azimuth Altitude:(float)altitude {
    [self orientToVector:GLKVector3Make(-cosf(azimuth), sinf(altitude), sinf(azimuth))];
}

-(void)updateLook {
    _lookVector = GLKVector3Make(-_attitudeMatrix.m02,
                                 -_attitudeMatrix.m12,
                                 -_attitudeMatrix.m22);
    _lookAzimuth = atan2f(_lookVector.x, -_lookVector.z);
    _lookAltitude = asinf(_lookVector.y);
}

-(CGPoint)imagePixelAtScreenLocation:(CGPoint)point {
    return [self imagePixelFromVector:[self vectorFromScreenLocation:point inAttitude:_attitudeMatrix]];
}

-(CGPoint)imagePixelFromVector:(GLKVector3)vector {
    CGPoint pxl = CGPointMake((M_PI - atan2f(-vector.z, -vector.x)) / (2 * M_PI),
                              acosf(vector.y) / M_PI);
    const CGPoint tex = [sphere getTextureSize];
    // if no texture exists, returns between 0.0 - 1.0
    if(!(tex.x == 0.f && tex.y == 0.f)) {
        pxl.x *= tex.x;
        pxl.y *= tex.y;
    }
    return pxl;
}

-(GLKVector3)vectorFromScreenLocation:(CGPoint)point {
    return [self vectorFromScreenLocation:point inAttitude:_attitudeMatrix];
}

-(GLKVector3)vectorFromScreenLocation:(CGPoint)point inAttitude:(GLKMatrix4)matrix {
    GLKMatrix4 inverse = GLKMatrix4Invert(GLKMatrix4Multiply(_projectionMatrix, matrix), nil);
    GLKVector4 screen = GLKVector4Make(2.0 * (point.x / CGRectGetWidth(self.frame) - .5),
                                       2.0 * (.5 - point.y / CGRectGetHeight(self.frame)),
                                       1.0, 1.0);
    //    if (GetSensorOrientation() == SensorOrientationSouth || GetSensorOrientation() == SensorOrientationWest)
    //        screen = GLKVector4Make(2.0*(screenTouch.x/self.frame.size.height-.5),
    //                                2.0*(.5-screenTouch.y/self.frame.size.width),
    //                                1.0, 1.0);
    GLKVector4 vec = GLKMatrix4MultiplyVector4(inverse, screen);
    return GLKVector3Normalize(GLKVector3Make(vec.x, vec.y, vec.z));
}

-(CGPoint)screenLocationFromVector:(GLKVector3)vector {
    GLKMatrix4 matrix = GLKMatrix4Multiply(_projectionMatrix, _attitudeMatrix);
    GLKVector3 screenVector = GLKMatrix4MultiplyVector3(matrix, vector);
    return CGPointMake((screenVector.x / screenVector.z / 2.0 + 0.5) * CGRectGetWidth(self.frame),
                       (0.5 - screenVector.y / screenVector.z / 2) * CGRectGetHeight(self.frame));
}

-(BOOL)computeScreenLocation:(CGPoint*)location fromVector:(GLKVector3)vector inAttitude:(GLKMatrix4)matrix {
    //This method returns whether the point is before or behind the screen.
    if(location == NULL) {
        return NO;
    }
    matrix = GLKMatrix4Multiply(_projectionMatrix, matrix);
    GLKVector4 vector4 = GLKVector4Make(vector.x, vector.y, vector.z, 1);
    GLKVector4 screenVector = GLKMatrix4MultiplyVector4(matrix, vector4);
    location->x = (screenVector.x / screenVector.w / 2.0 + 0.5) * CGRectGetWidth(self.frame);
    location->y = (0.5 - screenVector.y / screenVector.w / 2.0) * CGRectGetHeight(self.frame);
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
            zoom = _fieldOfView;
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
            touchVector = [self vectorFromScreenLocation:[sender locationInView:sender.view] inAttitude:_offsetMatrix];
        }
        case UIGestureRecognizerStateChanged: {
            GLKVector3 nowVector = [self vectorFromScreenLocation:[sender locationInView:sender.view] inAttitude:_offsetMatrix];
            GLKQuaternion q = GLKQuaternionFromTwoVectors(touchVector, nowVector);
            _offsetMatrix = GLKMatrix4Multiply(_offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
            // in progress for preventHeadTilt
            //        GLKMatrix4 mat = GLKMatrix4Multiply(_offsetMatrix, GLKMatrix4MakeWithQuaternion(q));
            //        _offsetMatrix = GLKMatrix4MakeLookAt(0, 0, 0, -mat.m02, -mat.m12, -mat.m22,  0, 1, 0);
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

@interface Sphere () {
    //  from Touch Fighter by Apple
    //  in Pro OpenGL ES for iOS
    //  by Mike Smithwick Jan 2011 pg. 78
    GLKTextureInfo *m_TextureInfo;
    GLfloat *m_TexCoordsData;
    GLfloat *m_VertexData;
    GLfloat *m_NormalData;
    GLint m_Stacks, m_Slices;
    GLfloat m_Scale;
}

-(GLKTextureInfo *)loadTextureFromBundle:(NSString *)filename;
-(GLKTextureInfo *)loadTextureFromPath:(NSString *)path;

@end

@implementation Sphere

-(id)init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile {
    // modifications:
    //   flipped(inverted)texture coords across the Z
    //   vertices rotated 90deg
    if(self = [super init]) {
        if(textureFile != nil) {
            m_TextureInfo = [self loadTextureFromBundle:textureFile];
        }
        m_Scale = radius;

        m_Stacks = stacks;
        m_Slices = slices;
        // Vertices
        GLfloat *vPtr = m_VertexData = (GLfloat*)malloc(sizeof(GLfloat) * 3 * ((m_Slices * 2 + 2) * m_Stacks));
        // Normals
        GLfloat *nPtr = m_NormalData = (GLfloat*)malloc(sizeof(GLfloat) * 3 * ((m_Slices * 2 + 2) * m_Stacks));
        GLfloat *tPtr = m_TexCoordsData = (GLfloat*)malloc(sizeof(GLfloat) * 2 * ((m_Slices * 2 + 2) * m_Stacks));
        // Latitude
        for(unsigned phiIdx = 0; phiIdx < m_Stacks; phiIdx++) {
            //starts at -pi/2 goes to pi/2
            //the first circle
            const float phi0 = M_PI * ((float)(phiIdx+0) * (1.0/(float)(m_Stacks)) - 0.5);
            //second one
            const float phi1 = M_PI * ((float)(phiIdx+1) * (1.0/(float)(m_Stacks)) - 0.5);
            const float cosPhi0 = cos(phi0);
            const float sinPhi0 = sin(phi0);
            const float cosPhi1 = cos(phi1);
            const float sinPhi1 = sin(phi1);
            //longitude
            for(unsigned thetaIdx = 0; thetaIdx < m_Slices; thetaIdx++) {
                const float theta = -2.0*M_PI * ((float)thetaIdx) * (1.0 / (float)(m_Slices - 1));
                const float cosTheta = cos(theta + M_PI * .5);
                const float sinTheta = sin(theta + M_PI * .5);
                //get x-y-x of the first vertex of stack
                vPtr[0] = m_Scale * cosPhi0 * cosTheta;
                vPtr[1] = m_Scale * sinPhi0;
                vPtr[2] = m_Scale * (cosPhi0 * sinTheta);
                //the same but for the vertex immediately above the previous one.
                vPtr[3] = m_Scale * cosPhi1 * cosTheta;
                vPtr[4] = m_Scale * sinPhi1;
                vPtr[5] = m_Scale * (cosPhi1 * sinTheta);
                nPtr[0] = cosPhi0 * cosTheta;
                nPtr[1] = sinPhi0;
                nPtr[2] = cosPhi0 * sinTheta;
                nPtr[3] = cosPhi1 * cosTheta;
                nPtr[4] = sinPhi1;
                nPtr[5] = cosPhi1 * sinTheta;
				
				GLfloat texX = (float)thetaIdx * (1.f / (float)(m_Slices - 1));
				tPtr[0] = 1.0 - texX;
				tPtr[1] = (float)(phiIdx + 0) * (1.f / (float)(m_Stacks));
				tPtr[2] = 1.0 - texX;
				tPtr[3] = (float)(phiIdx + 1) * (1.f / (float)(m_Stacks));
				
                vPtr += 2 * 3;
                nPtr += 2 * 3;
                tPtr += 2 * 2;
            }
            //Degenerate triangle to connect stacks and maintain winding order
            vPtr[0] = vPtr[3] = vPtr[-3];
            vPtr[1] = vPtr[4] = vPtr[-2];
            vPtr[2] = vPtr[5] = vPtr[-1];
            nPtr[0] = nPtr[3] = nPtr[-3];
            nPtr[1] = nPtr[4] = nPtr[-2];
            nPtr[2] = nPtr[5] = nPtr[-1];
			
			tPtr[0] = tPtr[2] = tPtr[-2];
			tPtr[1] = tPtr[3] = tPtr[-1];
        }
    }
    return self;
}

-(void)dealloc {
    GLuint name = m_TextureInfo.name;
    glDeleteTextures(1, &name);

    if(m_TexCoordsData != nil) {
        free(m_TexCoordsData);
    }
    if(m_NormalData != nil) {
        free(m_NormalData);
    }
    if(m_VertexData != nil) {
        free(m_VertexData);
    }
}

-(bool)execute {
    glEnableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
    if(m_TexCoordsData != nil) {
        glEnable(GL_TEXTURE_2D);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        if(m_TextureInfo != 0) {
            glBindTexture(GL_TEXTURE_2D, m_TextureInfo.name);
        }
        glTexCoordPointer(2, GL_FLOAT, 0, m_TexCoordsData);
    }
    glVertexPointer(3, GL_FLOAT, 0, m_VertexData);
    glNormalPointer(GL_FLOAT, 0, m_NormalData);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, (m_Slices + 1) * 2 * (m_Stacks - 1) + 2);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisable(GL_TEXTURE_2D);
    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
    return true;
}

-(GLKTextureInfo *)loadTextureFromBundle:(NSString *)filename {
    if(!filename) {
        return nil;
    }

    NSString *path = [[NSBundle mainBundle] pathForResource:filename ofType:NULL];
    return [self loadTextureFromPath:path];
}

-(GLKTextureInfo *)loadTextureFromPath:(NSString *)path {
    if(!path) {
        return nil;
    }

    UIImage *image = [UIImage imageWithContentsOfFile:path];
	return [self loadTextureFromUIImage:image withOptions:@{
															GLKTextureLoaderApplyPremultiplication: @YES,
															}];
}

-(GLKTextureInfo *)loadTextureFromUIImage:(UIImage *)image {
	return [self loadTextureFromUIImage:image withOptions:nil];
}

-(GLKTextureInfo *)loadTextureFromUIImage:(UIImage *)image withOptions:(NSDictionary *)extraOptions {
	if(!image) {
		return nil;
	}
	
	NSDictionary *options = nil;
	
	{
		NSMutableDictionary *mutableOptions = [NSMutableDictionary new];
		if(extraOptions) {
			[mutableOptions addEntriesFromDictionary:extraOptions];
		}
		[mutableOptions setObject:@YES forKey:GLKTextureLoaderOriginBottomLeft];
	
		options = mutableOptions;
	}
	
	
	NSLog(@"glGetError(): %@", @(glGetError()));
	
	NSError *error = nil;
	GLKTextureInfo *const info = [GLKTextureLoader textureWithCGImage: image.CGImage
															  options: options
																error: &error];
	
	if(error) {
		NSLog(@"error: %@", error);
		return nil;
	}
	
	if(!info) {
		return nil;
	}
	
	glBindTexture(GL_TEXTURE_2D, info.name);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, IMAGE_SCALING);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, IMAGE_SCALING);
	
	return info;
}


-(void)swapTextureWithImage:(UIImage *)image {
    GLuint name = m_TextureInfo.name;
    glDeleteTextures(1, &name);

    m_TextureInfo = [self loadTextureFromUIImage:image];
}

-(void)swapTexture:(NSString*)textureFile {
    GLuint name = m_TextureInfo.name;
    glDeleteTextures(1, &name);

    BOOL isDirectory = NO;
    if([NSFileManager.defaultManager fileExistsAtPath:textureFile isDirectory:&isDirectory] && !isDirectory) {
        m_TextureInfo = [self loadTextureFromPath:textureFile];
    } else {
        m_TextureInfo = [self loadTextureFromBundle:textureFile];
    }
}

-(CGPoint)getTextureSize {
    if(m_TextureInfo) {
        return CGPointMake(m_TextureInfo.width, m_TextureInfo.height);
    } else {
        return CGPointZero;
    }
}

@end
