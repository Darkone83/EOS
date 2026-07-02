// eos_ftol.cpp -- __ftol2_sse shim.
//
// This title links no CRT, so the compiler's float->int conversion helper
// (__ftol2_sse) is absent. The 3D pass needs real float math (projection,
// viewport, billboard positions), which the compiler lowers through this
// helper. Naked x87 shim: value arrives on the FPU stack (ST(0)); result is
// returned in EDX:EAX (low/high), which also satisfies 32-bit int callers via
// EAX. Same approach DarkDash uses (dd_ftol.cpp).
//
// NOTE: compile with the same code-gen settings as the rest of the project
// (/GL on, like every other .cpp) or the linker reports LNK2016.

extern "C" __declspec(naked) void _ftol2_sse()
{
    __asm
    {
        sub   esp, 8
        fistp qword ptr[esp]
        mov   eax, dword ptr[esp]
        mov   edx, dword ptr[esp + 4]
        add   esp, 8
        ret
    }
}