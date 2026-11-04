// The GLFW C API, translated once into the "glfw" module (see build.zig).
//
// GLFW_INCLUDE_NONE stops glfw3.h from pulling in the system GL header:
// OpenGL comes from glad, through renderer/gl.zig, and keeping the two
// apart avoids clashing declarations.
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
