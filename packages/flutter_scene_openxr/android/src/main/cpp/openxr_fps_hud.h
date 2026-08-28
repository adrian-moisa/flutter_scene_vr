#pragma once

#include <GLES3/gl3.h>
#include <array>
#include <cstdio>

namespace openxr_panels {

// GPU-only diagnostic button. No Flutter widget, Canvas, image upload, font
// dependency, or Dart callback is needed to paint or click this tiny layer.
inline std::array<unsigned char,7> Glyph(char c) {
    switch(c) {
        case '0': return {14,17,19,21,25,17,14};
        case '1': return {4,12,4,4,4,4,14};
        case '2': return {14,17,1,2,4,8,31};
        case '3': return {30,1,1,14,1,1,30};
        case '4': return {2,6,10,18,31,2,2};
        case '5': return {31,16,16,30,1,1,30};
        case '6': return {14,16,16,30,17,17,14};
        case '7': return {31,1,2,4,8,8,8};
        case '8': return {14,17,17,14,17,17,14};
        case '9': return {14,17,17,15,1,1,14};
        case 'F': return {31,16,16,30,16,16,16};
        case 'P': return {30,17,17,30,16,16,16};
        case 'S': return {15,16,16,14,1,1,30};
        case 'U': return {17,17,17,17,17,17,14};
        case 'I': return {14,4,4,4,4,4,14};
        case 'O': return {14,17,17,17,17,17,14};
        case 'N': return {17,25,25,21,19,19,17};
        default: return {};
    }
}

inline void DrawFpsHud(GLuint framebuffer, GLuint texture, int fps, bool paused, bool hover) {
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    glViewport(0,0,460,130);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
    glClearColor(hover ? .12f : .018f, .025f, hover ? .18f : .04f, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glClearColor(paused ? .15f : .7f, paused ? 1.0f : .6f, 1.0f, 1);
    std::array<char,32> label{};
    std::snprintf(label.data(),label.size(),"%3d FPS",fps);
    auto text = [](const char* value,int x,int y,int scale) {
        for (int i=0;value[i];++i) {
            const auto rows=Glyph(value[i]);
            for(int row=0;row<7;++row) for(int col=0;col<5;++col) {
                if((rows[row] & (1 << (4-col))) == 0) continue;
                glScissor(x+i*6*scale+col*scale, y+(6-row)*scale, scale,scale);
                glClear(GL_COLOR_BUFFER_BIT);
            }
        }
    };
    text(label.data(),83,63,7);
    text(paused ? "UI OFF" : "UI ON",140,14,5);
    glDisable(GL_SCISSOR_TEST);
    glFlush();
}
} // namespace openxr_panels
