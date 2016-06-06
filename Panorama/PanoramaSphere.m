#include "PanoramaSphere.h"

#import <OpenGLES/ES1/gl.h>

// LINEAR for smoothing, NEAREST for pixelized
#define IMAGE_SCALING GL_LINEAR  // GL_NEAREST, GL_LINEAR

@interface PanoramaSphere () {
    GLfloat *m_TexCoordsData;
    GLfloat *m_VertexData;
    GLfloat *m_NormalData;
}

@property (strong, nonatomic) GLKTextureInfo *textureInfo;
@property (assign, nonatomic) GLint stacks;
@property (assign, nonatomic) GLint slices;

-(GLKTextureInfo *)loadTextureFromBundle:(NSString *)filename;
-(GLKTextureInfo *)loadTextureFromPath:(NSString *)path;
-(GLKTextureInfo *)loadTextureFromUIImage:(UIImage *)image;

@end

@implementation PanoramaSphere

-(id)init:(GLint)stacks slices:(GLint)slices radius:(GLfloat)radius textureFile:(NSString *)textureFile {
    // modifications:
    //   flipped(inverted)texture coords across the Z
    //   vertices rotated 90deg
    if(self = [super init]) {
        const CGFloat scale = radius;

        if(textureFile != nil) {
            self.textureInfo = [self loadTextureFromBundle:textureFile];
        }

        self.stacks = stacks;
        self.slices = slices;
		
		const GLfloat div_1_stacks = 1. / self.stacks;
		
        // Vertices
        GLfloat *vPtr = m_VertexData = (GLfloat *)malloc(sizeof(GLfloat) * 3 * ((self.slices * (2 + 2)) * self.stacks));
        // Normals
        GLfloat *nPtr = m_NormalData = (GLfloat *)malloc(sizeof(GLfloat) * 3 * ((self.slices * (2 + 2)) * self.stacks));
        GLfloat *tPtr = m_TexCoordsData = (GLfloat *)malloc(sizeof(GLfloat) * 2 * ((self.slices * (2 + 2)) * self.stacks));

        // Latitude
        for(unsigned phiIdx = 0; phiIdx < self.stacks; ++phiIdx) {
            //starts at -pi/2 goes to pi/2

            //the first circle
            const GLfloat phi0 = M_PI * ((GLfloat)(phiIdx + 0) * div_1_stacks - .5);
            const GLfloat cosPhi0 = cos(phi0);
            const GLfloat sinPhi0 = sin(phi0);

            //second one
            const GLfloat phi1 = M_PI * ((GLfloat)(phiIdx + 1) * div_1_stacks - .5);
            const GLfloat cosPhi1 = cos(phi1);
            const GLfloat sinPhi1 = sin(phi1);

            //longitude
            for(unsigned thetaIdx = 0; thetaIdx < self.slices; ++thetaIdx) {
                const GLfloat theta = -2.0 * M_PI * ((GLfloat)thetaIdx) * (1. / (self.slices - 1));
                const GLfloat cosTheta = cos(theta + M_PI_2);
                const GLfloat sinTheta = sin(theta + M_PI_2);

                nPtr[0] = cosPhi0 * cosTheta;
                nPtr[1] = sinPhi0;
                nPtr[2] = cosPhi0 * sinTheta;
                nPtr[3] = cosPhi1 * cosTheta;
                nPtr[4] = sinPhi1;
                nPtr[5] = cosPhi1 * sinTheta;

                vPtr[0] = scale * nPtr[0];
                vPtr[1] = scale * nPtr[1];
                vPtr[2] = scale * nPtr[2];
                vPtr[3] = scale * nPtr[3];
                vPtr[4] = scale * nPtr[4];
                vPtr[5] = scale * nPtr[5];
				
				const GLfloat texX = (GLfloat)thetaIdx * (1. / (self.slices - 1));
				tPtr[0] = 1. - texX;
				tPtr[1] = (GLfloat)(phiIdx + 0) * div_1_stacks;
				tPtr[2] = 1. - texX;
				tPtr[3] = (GLfloat)(phiIdx + 1) * div_1_stacks;
				
                nPtr += (2 * 3);
                vPtr += (2 * 3);
				tPtr += (2 * 2);
            }

            //Degenerate triangle to connect stacks and maintain winding order
            nPtr[0] = nPtr[3] = nPtr[-3];
            nPtr[1] = nPtr[4] = nPtr[-2];
            nPtr[2] = nPtr[5] = nPtr[-1];

            vPtr[0] = vPtr[3] = vPtr[-3];
            vPtr[1] = vPtr[4] = vPtr[-2];
            vPtr[2] = vPtr[5] = vPtr[-1];

			tPtr[0] = tPtr[2] = tPtr[-2];
			tPtr[1] = tPtr[3] = tPtr[-1];
        }
    }
    return self;
}

-(void)dealloc {
    GLuint name = self.textureInfo.name;
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

-(void)render {
    glEnableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_VERTEX_ARRAY);
	glEnable(GL_TEXTURE_2D);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	if(self.textureInfo != 0) {
		glBindTexture(GL_TEXTURE_2D, self.textureInfo.name);
	}
    if(m_TexCoordsData != nil) {
        glTexCoordPointer(2, GL_FLOAT, 0, m_TexCoordsData);
    }
    glVertexPointer(3, GL_FLOAT, 0, m_VertexData);
    glNormalPointer(GL_FLOAT, 0, m_NormalData);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, (self.slices + 1) * 2 * (self.stacks - 1) + 2);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisable(GL_TEXTURE_2D);
    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
}

-(void)swapTextureWithImage:(UIImage *)image {
    GLuint name = self.textureInfo.name;
    glDeleteTextures(1, &name);

    self.textureInfo = [self loadTextureFromUIImage:image];
}

-(void)swapTexture:(NSString*)textureFile {
    GLuint name = self.textureInfo.name;
    glDeleteTextures(1, &name);

    BOOL isDirectory = NO;
    if([NSFileManager.defaultManager fileExistsAtPath:textureFile isDirectory:&isDirectory] && !isDirectory) {
        self.textureInfo = [self loadTextureFromPath:textureFile];
    } else {
        self.textureInfo = [self loadTextureFromBundle:textureFile];
    }
}

#pragma mark - HELPERS

-(CGPoint)imagePixelFromVector:(GLKVector3)vector {
    CGPoint pxl = CGPointMake((M_PI - atan2f(-vector.z, -vector.x)) / (2 * M_PI),
                              acosf(vector.y) / M_PI);
    const CGSize size = CGSizeMake(self.textureInfo.width, self.textureInfo.height);
    // if no texture exists, returns between 0.0 - 1.0
    if(!(size.width == 0.f && size.height == 0.f)) {
        pxl.x *= size.width;
        pxl.y *= size.height;
    }
    return pxl;
}

-(GLKTextureInfo *)loadTextureFromBundle:(NSString *)filename {
    if(!filename) {
        return nil;
    }

    NSString *const path = [[NSBundle mainBundle] pathForResource:filename ofType:NULL];
    return [self loadTextureFromPath:path];
}

-(GLKTextureInfo *)loadTextureFromPath:(NSString *)path {
    if(!path) {
        return nil;
    }

    UIImage *const image = [UIImage imageWithContentsOfFile:path];
    return [self loadTextureFromUIImage:image];
}

-(GLKTextureInfo *)loadTextureFromUIImage:(UIImage *)image {
    if(!image) {
        return nil;
    }

    NSDictionary *const options = @{
									GLKTextureLoaderOriginBottomLeft: @(YES)
									};
	(void)glGetError();
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

@end
