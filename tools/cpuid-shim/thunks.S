.intel_syntax noprefix
.text
.globl generic_thunk

generic_thunk:
    push rbp
    mov  rbp, rsp
    sub  rsp, 0x130
    movups [rbp-0xB0], xmm0
    movups [rbp-0xA0], xmm1
    movups [rbp-0x90], xmm2
    movups [rbp-0x80], xmm3
    lea  rax, [rbp-0x70]
    mov  [rax+0],  r10
    mov  [rax+8],  rcx
    mov  [rax+16], rdx
    mov  [rax+24], r8
    mov  [rax+32], r9
    mov  r11, [rbp+0x30]
    mov  [rax+40], r11
    mov  r11, [rbp+0x38]
    mov  [rax+48], r11
    mov  r11, [rbp+0x40]
    mov  [rax+56], r11
    mov  r11, [rbp+0x48]
    mov  [rax+64], r11
    mov  r11, [rbp+0x50]
    mov  [rax+72], r11
    mov  r11, [rbp+0x58]
    mov  [rax+80], r11
    mov  rcx, rax
    call on_call
    mov  r11d, 12
    lea  r10, [rbp+0x30]
    lea  rdx, [rsp+0x20]
copy_loop:
    mov  rax, [r10]
    mov  [rdx], rax
    add  r10, 8
    add  rdx, 8
    dec  r11d
    jnz  copy_loop
    movups xmm0, [rbp-0xB0]
    movups xmm1, [rbp-0xA0]
    movups xmm2, [rbp-0x90]
    movups xmm3, [rbp-0x80]
    lea  r11, [rbp-0x70]
    mov  rcx, [r11+8]
    mov  rdx, [r11+16]
    mov  r8,  [r11+24]
    mov  r9,  [r11+32]
    mov  r10, [r11+0]
    lea  rax, [rip+slot_fn]
    mov  rax, [rax+r10*8]
    call rax
    lea  r11, [rbp-0x70]
    mov  [r11+88], rax
    movq [r11+96], xmm0
    mov  rcx, r11
    call on_ret
    lea  r11, [rbp-0x70]
    mov  rax, [r11+88]
    movq xmm0, [r11+96]
    mov  rsp, rbp
    pop  rbp
    ret

t0:
    mov r10d, 0
    jmp generic_thunk

t1:
    mov r10d, 1
    jmp generic_thunk

t2:
    mov r10d, 2
    jmp generic_thunk

t3:
    mov r10d, 3
    jmp generic_thunk

t4:
    mov r10d, 4
    jmp generic_thunk

t5:
    mov r10d, 5
    jmp generic_thunk

t6:
    mov r10d, 6
    jmp generic_thunk

t7:
    mov r10d, 7
    jmp generic_thunk

t8:
    mov r10d, 8
    jmp generic_thunk

t9:
    mov r10d, 9
    jmp generic_thunk

t10:
    mov r10d, 10
    jmp generic_thunk

t11:
    mov r10d, 11
    jmp generic_thunk

t12:
    mov r10d, 12
    jmp generic_thunk

t13:
    mov r10d, 13
    jmp generic_thunk

t14:
    mov r10d, 14
    jmp generic_thunk

t15:
    mov r10d, 15
    jmp generic_thunk

t16:
    mov r10d, 16
    jmp generic_thunk

t17:
    mov r10d, 17
    jmp generic_thunk

t18:
    mov r10d, 18
    jmp generic_thunk

t19:
    mov r10d, 19
    jmp generic_thunk

t20:
    mov r10d, 20
    jmp generic_thunk

t21:
    mov r10d, 21
    jmp generic_thunk

t22:
    mov r10d, 22
    jmp generic_thunk

t23:
    mov r10d, 23
    jmp generic_thunk

t24:
    mov r10d, 24
    jmp generic_thunk

t25:
    mov r10d, 25
    jmp generic_thunk

t26:
    mov r10d, 26
    jmp generic_thunk

t27:
    mov r10d, 27
    jmp generic_thunk

t28:
    mov r10d, 28
    jmp generic_thunk

t29:
    mov r10d, 29
    jmp generic_thunk

t30:
    mov r10d, 30
    jmp generic_thunk

t31:
    mov r10d, 31
    jmp generic_thunk

t32:
    mov r10d, 32
    jmp generic_thunk

t33:
    mov r10d, 33
    jmp generic_thunk

t34:
    mov r10d, 34
    jmp generic_thunk

t35:
    mov r10d, 35
    jmp generic_thunk

t36:
    mov r10d, 36
    jmp generic_thunk

t37:
    mov r10d, 37
    jmp generic_thunk

t38:
    mov r10d, 38
    jmp generic_thunk

t39:
    mov r10d, 39
    jmp generic_thunk

t40:
    mov r10d, 40
    jmp generic_thunk

t41:
    mov r10d, 41
    jmp generic_thunk

t42:
    mov r10d, 42
    jmp generic_thunk

t43:
    mov r10d, 43
    jmp generic_thunk

t44:
    mov r10d, 44
    jmp generic_thunk

t45:
    mov r10d, 45
    jmp generic_thunk

t46:
    mov r10d, 46
    jmp generic_thunk

t47:
    mov r10d, 47
    jmp generic_thunk

t48:
    mov r10d, 48
    jmp generic_thunk

t49:
    mov r10d, 49
    jmp generic_thunk

t50:
    mov r10d, 50
    jmp generic_thunk

t51:
    mov r10d, 51
    jmp generic_thunk

t52:
    mov r10d, 52
    jmp generic_thunk

t53:
    mov r10d, 53
    jmp generic_thunk

t54:
    mov r10d, 54
    jmp generic_thunk

t55:
    mov r10d, 55
    jmp generic_thunk

t56:
    mov r10d, 56
    jmp generic_thunk

t57:
    mov r10d, 57
    jmp generic_thunk

t58:
    mov r10d, 58
    jmp generic_thunk

t59:
    mov r10d, 59
    jmp generic_thunk

t60:
    mov r10d, 60
    jmp generic_thunk

t61:
    mov r10d, 61
    jmp generic_thunk

t62:
    mov r10d, 62
    jmp generic_thunk

t63:
    mov r10d, 63
    jmp generic_thunk

.data
.globl thunk_table
thunk_table:
    .quad t0
    .quad t1
    .quad t2
    .quad t3
    .quad t4
    .quad t5
    .quad t6
    .quad t7
    .quad t8
    .quad t9
    .quad t10
    .quad t11
    .quad t12
    .quad t13
    .quad t14
    .quad t15
    .quad t16
    .quad t17
    .quad t18
    .quad t19
    .quad t20
    .quad t21
    .quad t22
    .quad t23
    .quad t24
    .quad t25
    .quad t26
    .quad t27
    .quad t28
    .quad t29
    .quad t30
    .quad t31
    .quad t32
    .quad t33
    .quad t34
    .quad t35
    .quad t36
    .quad t37
    .quad t38
    .quad t39
    .quad t40
    .quad t41
    .quad t42
    .quad t43
    .quad t44
    .quad t45
    .quad t46
    .quad t47
    .quad t48
    .quad t49
    .quad t50
    .quad t51
    .quad t52
    .quad t53
    .quad t54
    .quad t55
    .quad t56
    .quad t57
    .quad t58
    .quad t59
    .quad t60
    .quad t61
    .quad t62
    .quad t63
