//! The GLAD-loaded OpenGL types, constants and functions rex uses.
//! Export only what is used; add more here as the renderer needs them.

const std = @import("std");

const c = @cImport({
    @cInclude("glad/glad.h");
});

test {
    std.testing.refAllDecls(@This());
}

// Types
pub const GLuint = c.GLuint;
pub const GLint = c.GLint;
pub const GLsizei = c.GLsizei;
pub const GLsizeiptr = c.GLsizeiptr;
pub const GLintptr = c.GLintptr;
pub const GLenum = c.GLenum;
pub const GLfloat = c.GLfloat;
pub const GLADloadproc = c.GLADloadproc;

// Constants
pub const UNPACK_ROW_LENGTH = c.GL_UNPACK_ROW_LENGTH;
pub const ARRAY_BUFFER = c.GL_ARRAY_BUFFER;
pub const STATIC_DRAW = c.GL_STATIC_DRAW;
pub const DYNAMIC_DRAW = c.GL_DYNAMIC_DRAW;
pub const FLOAT = c.GL_FLOAT;
pub const SHORT = c.GL_SHORT;
pub const UNSIGNED_SHORT = c.GL_UNSIGNED_SHORT;
pub const UNSIGNED_INT = c.GL_UNSIGNED_INT;
pub const UNSIGNED_BYTE = c.GL_UNSIGNED_BYTE;
pub const FALSE = c.GL_FALSE;
pub const TRUE = c.GL_TRUE;
pub const ONE = c.GL_ONE;
pub const TRIANGLES = c.GL_TRIANGLES;
pub const TRIANGLE_STRIP = c.GL_TRIANGLE_STRIP;
pub const TRIANGLE_FAN = c.GL_TRIANGLE_FAN;
pub const TEXTURE_2D = c.GL_TEXTURE_2D;
pub const MAX_TEXTURE_SIZE = c.GL_MAX_TEXTURE_SIZE;
pub const TEXTURE1 = c.GL_TEXTURE1;
pub const TEXTURE0 = c.GL_TEXTURE0;
pub const COLOR_BUFFER_BIT = c.GL_COLOR_BUFFER_BIT;
pub const VERTEX_SHADER = c.GL_VERTEX_SHADER;
pub const FRAGMENT_SHADER = c.GL_FRAGMENT_SHADER;
pub const COMPILE_STATUS = c.GL_COMPILE_STATUS;
pub const LINK_STATUS = c.GL_LINK_STATUS;
pub const R8 = c.GL_R8;
pub const RED = c.GL_RED;
pub const RGBA8 = c.GL_RGBA8;
pub const RGBA = c.GL_RGBA;
pub const BGRA = c.GL_BGRA;
pub const UNPACK_ALIGNMENT = c.GL_UNPACK_ALIGNMENT;
pub const PACK_ALIGNMENT = c.GL_PACK_ALIGNMENT;
pub const COLOR_CLEAR_VALUE = c.GL_COLOR_CLEAR_VALUE;
pub const FRAMEBUFFER_BINDING = c.GL_FRAMEBUFFER_BINDING;
pub const TEXTURE_MIN_FILTER = c.GL_TEXTURE_MIN_FILTER;
pub const TEXTURE_MAG_FILTER = c.GL_TEXTURE_MAG_FILTER;
pub const NEAREST = c.GL_NEAREST;
pub const LINEAR = c.GL_LINEAR;
pub const CLAMP_TO_EDGE = c.GL_CLAMP_TO_EDGE;
pub const BLEND = c.GL_BLEND;
pub const SRC_ALPHA = c.GL_SRC_ALPHA;
pub const ONE_MINUS_SRC_ALPHA = c.GL_ONE_MINUS_SRC_ALPHA;
pub const TEXTURE_WRAP_S = c.GL_TEXTURE_WRAP_S;
pub const TEXTURE_WRAP_T = c.GL_TEXTURE_WRAP_T;
pub const TEXTURE_SWIZZLE_RGBA = c.GL_TEXTURE_SWIZZLE_RGBA;
pub const CONTEXT_PROFILE_MASK = c.GL_CONTEXT_PROFILE_MASK;
pub const CONTEXT_CORE_PROFILE_BIT = c.GL_CONTEXT_CORE_PROFILE_BIT;
pub const MAJOR_VERSION = c.GL_MAJOR_VERSION;
pub const MINOR_VERSION = c.GL_MINOR_VERSION;
pub const TEXTURE2 = c.GL_TEXTURE2;
pub const FRAMEBUFFER = c.GL_FRAMEBUFFER;
pub const COLOR_ATTACHMENT0 = c.GL_COLOR_ATTACHMENT0;
pub const FRAMEBUFFER_COMPLETE = c.GL_FRAMEBUFFER_COMPLETE;
pub const FUNC_ADD = c.GL_FUNC_ADD;
pub const MAX = c.GL_MAX;

// Functions, re-exported so callers need no @cImport of their own.
pub const genVertexArrays = c.glGenVertexArrays;
pub const bindVertexArray = c.glBindVertexArray;
pub const deleteVertexArrays = c.glDeleteVertexArrays;
pub const genBuffers = c.glGenBuffers;
pub const bindBuffer = c.glBindBuffer;
pub const bufferData = c.glBufferData;
pub const bufferSubData = c.glBufferSubData;
pub const deleteBuffers = c.glDeleteBuffers;
pub const enableVertexAttribArray = c.glEnableVertexAttribArray;
pub const vertexAttribPointer = c.glVertexAttribPointer;
pub const vertexAttribIPointer = c.glVertexAttribIPointer;
pub const vertexAttribDivisor = c.glVertexAttribDivisor;
pub const drawArraysInstanced = c.glDrawArraysInstanced;
pub const drawArrays = c.glDrawArrays;
pub const createShader = c.glCreateShader;
pub const shaderSource = c.glShaderSource;
pub const compileShader = c.glCompileShader;
pub const getShaderiv = c.glGetShaderiv;
pub const getShaderInfoLog = c.glGetShaderInfoLog;
pub const deleteShader = c.glDeleteShader;
pub const createProgram = c.glCreateProgram;
pub const attachShader = c.glAttachShader;
pub const linkProgram = c.glLinkProgram;
pub const getProgramiv = c.glGetProgramiv;
pub const getProgramInfoLog = c.glGetProgramInfoLog;
pub const useProgram = c.glUseProgram;
pub const deleteProgram = c.glDeleteProgram;
pub const getUniformLocation = c.glGetUniformLocation;
pub const uniformMatrix4fv = c.glUniformMatrix4fv;
pub const uniform1i = c.glUniform1i;
pub const uniform1ui = c.glUniform1ui;
pub const uniform2ui = c.glUniform2ui;
pub const uniform4f = c.glUniform4f;
pub const uniform3f = c.glUniform3f;
pub const uniform2f = c.glUniform2f;
pub const uniform1f = c.glUniform1f;
pub const uniform2i = c.glUniform2i;
pub const clearColor = c.glClearColor;
pub const clear = c.glClear;
pub const viewport = c.glViewport;
pub const enable = c.glEnable;
pub const blendFuncSeparate = c.glBlendFuncSeparate;
pub const blendEquation = c.glBlendEquation;
pub const genFramebuffers = c.glGenFramebuffers;
pub const bindFramebuffer = c.glBindFramebuffer;
pub const framebufferTexture2D = c.glFramebufferTexture2D;
pub const checkFramebufferStatus = c.glCheckFramebufferStatus;
pub const deleteFramebuffers = c.glDeleteFramebuffers;
pub const genTextures = c.glGenTextures;
pub const bindTexture = c.glBindTexture;
pub const texImage2D = c.glTexImage2D;
pub const texSubImage2D = c.glTexSubImage2D;
pub const texParameteri = c.glTexParameteri;
pub const texParameteriv = c.glTexParameteriv;
pub const pixelStorei = c.glPixelStorei;
pub const activeTexture = c.glActiveTexture;
pub const deleteTextures = c.glDeleteTextures;
pub const getTexImage = c.glGetTexImage;
pub const gladLoadGLLoader = c.gladLoadGLLoader;
pub const getIntegerv = c.glGetIntegerv;
pub const getFloatv = c.glGetFloatv;
