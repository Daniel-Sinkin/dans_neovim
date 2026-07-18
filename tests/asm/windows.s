	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
@feat.00 = 0
	.file	"t.cpp"
	.def	"?add@@YAHHH@Z";
	.scl	2;
	.type	32;
	.endef
	.text
	.globl	"?add@@YAHHH@Z"                 # -- Begin function ?add@@YAHHH@Z
	.p2align	4
"?add@@YAHHH@Z":                        # @"?add@@YAHHH@Z"
.Lfunc_begin0:
	.cv_func_id 0
# %bb.0:
	#DEBUG_VALUE: add:b <- $edx
	#DEBUG_VALUE: add:a <- $ecx
	.cv_file	1 "E:\\repos\\neovim-cfg\\private\\t.cpp" "1A4584B231D04F670C9EAB377958159A" 1
	.cv_loc	0 1 3 0                         # private/t.cpp:3:0
                                        # kill: def $edx killed $edx def $rdx
                                        # kill: def $ecx killed $ecx def $rcx
	leal	(%rcx,%rdx), %eax
.Ltmp0:
	#DEBUG_VALUE: add:s <- $eax
	.cv_loc	0 1 4 0                         # private/t.cpp:4:0
	addl	%eax, %eax
.Ltmp1:
	retq
.Ltmp2:
.Lfunc_end0:
                                        # -- End function
	.def	"?mul@@YAHHH@Z";
	.scl	2;
	.type	32;
	.endef
	.globl	"?mul@@YAHHH@Z"                 # -- Begin function ?mul@@YAHHH@Z
	.p2align	4
"?mul@@YAHHH@Z":                        # @"?mul@@YAHHH@Z"
.Lfunc_begin1:
	.cv_func_id 1
	.cv_loc	1 1 7 0                         # private/t.cpp:7:0
# %bb.0:
	#DEBUG_VALUE: mul:b <- $edx
	#DEBUG_VALUE: mul:a <- $ecx
	movl	%ecx, %eax
.Ltmp3:
	imull	%edx, %eax
	retq
.Ltmp4:
.Lfunc_end1:
                                        # -- End function
	.section	.debug$S,"dr"
	.p2align	2, 0x0
	.long	4                               # Debug section magic
	.long	241
	.long	.Ltmp6-.Ltmp5                   # Subsection size
.Ltmp5:
	.short	.Ltmp8-.Ltmp7                   # Record length
.Ltmp7:
	.short	4353                            # Record kind: S_OBJNAME
	.long	0                               # Signature
	.asciz	"E:\\repos\\neovim-cfg\\tests\\asm\\windows.s" # Object name
	.p2align	2, 0x0
.Ltmp8:
	.short	.Ltmp10-.Ltmp9                  # Record length
.Ltmp9:
	.short	4412                            # Record kind: S_COMPILE3
	.long	1                               # Flags and language
	.short	208                             # CPUType
	.short	22                              # Frontend version
	.short	1
	.short	6
	.short	0
	.short	22016                           # Backend version
	.short	0
	.short	0
	.short	0
	.asciz	"clang version 22.1.6 (https://github.com/llvm/llvm-project fc4aad7b5db3fff421df9a9637605b9ca5667881)" # Null-terminated compiler version string
	.p2align	2, 0x0
.Ltmp10:
.Ltmp6:
	.p2align	2, 0x0
	.long	241                             # Symbol subsection for add
	.long	.Ltmp12-.Ltmp11                 # Subsection size
.Ltmp11:
	.short	.Ltmp14-.Ltmp13                 # Record length
.Ltmp13:
	.short	4423                            # Record kind: S_GPROC32_ID
	.long	0                               # PtrParent
	.long	0                               # PtrEnd
	.long	0                               # PtrNext
	.long	.Lfunc_end0-"?add@@YAHHH@Z"     # Code size
	.long	0                               # Offset after prologue
	.long	0                               # Offset before epilogue
	.long	4098                            # Function type index
	.secrel32	"?add@@YAHHH@Z"         # Function section relative address
	.secidx	"?add@@YAHHH@Z"                 # Function section index
	.byte	128                             # Flags
	.asciz	"add"                           # Function name
	.p2align	2, 0x0
.Ltmp14:
	.short	.Ltmp16-.Ltmp15                 # Record length
.Ltmp15:
	.short	4114                            # Record kind: S_FRAMEPROC
	.long	0                               # FrameSize
	.long	0                               # Padding
	.long	0                               # Offset of padding
	.long	0                               # Bytes of callee saved registers
	.long	0                               # Exception handler offset
	.short	0                               # Exception handler section
	.long	1056768                         # Flags (defines frame register)
	.p2align	2, 0x0
.Ltmp16:
	.short	.Ltmp18-.Ltmp17                 # Record length
.Ltmp17:
	.short	4414                            # Record kind: S_LOCAL
	.long	116                             # TypeIndex
	.short	1                               # Flags
	.asciz	"a"
	.p2align	2, 0x0
.Ltmp18:
	.cv_def_range	 .Lfunc_begin0 .Lfunc_end0, reg, 18
	.short	.Ltmp20-.Ltmp19                 # Record length
.Ltmp19:
	.short	4414                            # Record kind: S_LOCAL
	.long	116                             # TypeIndex
	.short	1                               # Flags
	.asciz	"b"
	.p2align	2, 0x0
.Ltmp20:
	.cv_def_range	 .Lfunc_begin0 .Lfunc_end0, reg, 19
	.short	.Ltmp22-.Ltmp21                 # Record length
.Ltmp21:
	.short	4414                            # Record kind: S_LOCAL
	.long	116                             # TypeIndex
	.short	0                               # Flags
	.asciz	"s"
	.p2align	2, 0x0
.Ltmp22:
	.cv_def_range	 .Ltmp0 .Ltmp1, reg, 17
	.short	2                               # Record length
	.short	4431                            # Record kind: S_PROC_ID_END
.Ltmp12:
	.p2align	2, 0x0
	.cv_linetable	0, "?add@@YAHHH@Z", .Lfunc_end0
	.long	241                             # Symbol subsection for mul
	.long	.Ltmp24-.Ltmp23                 # Subsection size
.Ltmp23:
	.short	.Ltmp26-.Ltmp25                 # Record length
.Ltmp25:
	.short	4423                            # Record kind: S_GPROC32_ID
	.long	0                               # PtrParent
	.long	0                               # PtrEnd
	.long	0                               # PtrNext
	.long	.Lfunc_end1-"?mul@@YAHHH@Z"     # Code size
	.long	0                               # Offset after prologue
	.long	0                               # Offset before epilogue
	.long	4099                            # Function type index
	.secrel32	"?mul@@YAHHH@Z"         # Function section relative address
	.secidx	"?mul@@YAHHH@Z"                 # Function section index
	.byte	128                             # Flags
	.asciz	"mul"                           # Function name
	.p2align	2, 0x0
.Ltmp26:
	.short	.Ltmp28-.Ltmp27                 # Record length
.Ltmp27:
	.short	4114                            # Record kind: S_FRAMEPROC
	.long	0                               # FrameSize
	.long	0                               # Padding
	.long	0                               # Offset of padding
	.long	0                               # Bytes of callee saved registers
	.long	0                               # Exception handler offset
	.short	0                               # Exception handler section
	.long	1056768                         # Flags (defines frame register)
	.p2align	2, 0x0
.Ltmp28:
	.short	.Ltmp30-.Ltmp29                 # Record length
.Ltmp29:
	.short	4414                            # Record kind: S_LOCAL
	.long	116                             # TypeIndex
	.short	1                               # Flags
	.asciz	"a"
	.p2align	2, 0x0
.Ltmp30:
	.cv_def_range	 .Lfunc_begin1 .Lfunc_end1, reg, 18
	.short	.Ltmp32-.Ltmp31                 # Record length
.Ltmp31:
	.short	4414                            # Record kind: S_LOCAL
	.long	116                             # TypeIndex
	.short	1                               # Flags
	.asciz	"b"
	.p2align	2, 0x0
.Ltmp32:
	.cv_def_range	 .Lfunc_begin1 .Lfunc_end1, reg, 19
	.short	2                               # Record length
	.short	4431                            # Record kind: S_PROC_ID_END
.Ltmp24:
	.p2align	2, 0x0
	.cv_linetable	1, "?mul@@YAHHH@Z", .Lfunc_end1
	.cv_filechecksums                       # File index to string table offset subsection
	.cv_stringtable                         # String table
	.long	241
	.long	.Ltmp34-.Ltmp33                 # Subsection size
.Ltmp33:
	.short	.Ltmp36-.Ltmp35                 # Record length
.Ltmp35:
	.short	4428                            # Record kind: S_BUILDINFO
	.long	4105                            # LF_BUILDINFO index
	.p2align	2, 0x0
.Ltmp36:
.Ltmp34:
	.p2align	2, 0x0
	.section	.debug$T,"dr"
	.p2align	2, 0x0
	.long	4                               # Debug section magic
	# ArgList (0x1000)
	.short	0xe                             # Record length
	.short	0x1201                          # Record kind: LF_ARGLIST
	.long	0x2                             # NumArgs
	.long	0x74                            # Argument: int
	.long	0x74                            # Argument: int
	# Procedure (0x1001)
	.short	0xe                             # Record length
	.short	0x1008                          # Record kind: LF_PROCEDURE
	.long	0x74                            # ReturnType: int
	.byte	0x0                             # CallingConvention: NearC
	.byte	0x0                             # FunctionOptions
	.short	0x2                             # NumParameters
	.long	0x1000                          # ArgListType: (int, int)
	# FuncId (0x1002)
	.short	0xe                             # Record length
	.short	0x1601                          # Record kind: LF_FUNC_ID
	.long	0x0                             # ParentScope
	.long	0x1001                          # FunctionType: int (int, int)
	.asciz	"add"                           # Name
	# FuncId (0x1003)
	.short	0xe                             # Record length
	.short	0x1601                          # Record kind: LF_FUNC_ID
	.long	0x0                             # ParentScope
	.long	0x1001                          # FunctionType: int (int, int)
	.asciz	"mul"                           # Name
	# StringId (0x1004)
	.short	0x1a                            # Record length
	.short	0x1605                          # Record kind: LF_STRING_ID
	.long	0x0                             # Id
	.asciz	"E:\\repos\\neovim-cfg"         # StringData
	# StringId (0x1005)
	.short	0x16                            # Record length
	.short	0x1605                          # Record kind: LF_STRING_ID
	.long	0x0                             # Id
	.asciz	"private\\t.cpp"                # StringData
	.byte	242
	.byte	241
	# StringId (0x1006)
	.short	0xa                             # Record length
	.short	0x1605                          # Record kind: LF_STRING_ID
	.long	0x0                             # Id
	.byte	0                               # StringData
	.byte	243
	.byte	242
	.byte	241
	# StringId (0x1007)
	.short	0x2e                            # Record length
	.short	0x1605                          # Record kind: LF_STRING_ID
	.long	0x0                             # Id
	.asciz	"C:\\Program Files\\LLVM\\bin\\clang++.exe" # StringData
	.byte	242
	.byte	241
	# StringId (0x1008)
	.short	0x76a                           # Record length
	.short	0x1605                          # Record kind: LF_STRING_ID
	.long	0x0                             # Id
	.asciz	"\"-cc1\" \"-triple\" \"x86_64-pc-windows-msvc19.44.35227\" \"-O2\" \"-S\" \"-disable-free\" \"-clear-ast-before-backend\" \"-disable-llvm-verifier\" \"-discard-value-names\" \"-mrelocation-model\" \"pic\" \"-pic-level\" \"2\" \"-mframe-pointer=none\" \"-relaxed-aliasing\" \"-fmath-errno\" \"-ffp-contract=on\" \"-fno-rounding-math\" \"-mconstructor-aliases\" \"-fms-volatile\" \"-funwind-tables=2\" \"-target-cpu\" \"x86-64\" \"-tune-cpu\" \"generic\" \"-gno-column-info\" \"-gcodeview\" \"-debug-info-kind=constructor\" \"-fdebug-compilation-dir=E:\\\\repos\\\\neovim-cfg\" \"-fcoverage-compilation-dir=E:\\\\repos\\\\neovim-cfg\" \"-resource-dir\" \"C:\\\\Program Files\\\\LLVM\\\\lib\\\\clang\\\\22\" \"-internal-isystem\" \"C:\\\\Program Files\\\\LLVM\\\\lib\\\\clang\\\\22\\\\include\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Microsoft Visual Studio\\\\2022\\\\BuildTools\\\\VC\\\\Tools\\\\MSVC\\\\14.44.35207\\\\include\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Microsoft Visual Studio\\\\2022\\\\BuildTools\\\\VC\\\\Auxiliary\\\\VS\\\\include\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\include\\\\10.0.26100.0\\\\ucrt\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\\\\\include\\\\10.0.26100.0\\\\\\\\um\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\\\\\include\\\\10.0.26100.0\\\\\\\\shared\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\\\\\include\\\\10.0.26100.0\\\\\\\\winrt\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\\\\\include\\\\10.0.26100.0\\\\\\\\cppwinrt\" \"-internal-isystem\" \"C:\\\\Program Files (x86)\\\\Windows Kits\\\\NETFXSDK\\\\4.6.1\\\\include\\\\um\" \"-internal-isystem\" \"G:\\\\Program Files\\\\NAG\\\\DC33\\\\dcw6i33nal\\\\include\" \"-fdeprecated-macro\" \"-ferror-limit\" \"19\" \"-fno-use-cxa-atexit\" \"-fms-extensions\" \"-fms-compatibility\" \"-fms-compatibility-version=19.44.35227\" \"-std=c++14\" \"-fskip-odr-check-in-gmf\" \"-fdelayed-template-parsing\" \"-fcxx-exceptions\" \"-fexceptions\" \"-vectorize-loops\" \"-vectorize-slp\" \"-faddrsig\" \"-x\" \"c++\"" # StringData
	# BuildInfo (0x1009)
	.short	0x1a                            # Record length
	.short	0x1603                          # Record kind: LF_BUILDINFO
	.short	0x5                             # NumArgs
	.long	0x1004                          # Argument: E:\repos\neovim-cfg
	.long	0x1007                          # Argument: C:\Program Files\LLVM\bin\clang++.exe
	.long	0x1005                          # Argument: private\t.cpp
	.long	0x1006                          # Argument
	.long	0x1008                          # Argument: "-cc1" "-triple" "x86_64-pc-windows-msvc19.44.35227" "-O2" "-S" "-disable-free" "-clear-ast-before-backend" "-disable-llvm-verifier" "-discard-value-names" "-mrelocation-model" "pic" "-pic-level" "2" "-mframe-pointer=none" "-relaxed-aliasing" "-fmath-errno" "-ffp-contract=on" "-fno-rounding-math" "-mconstructor-aliases" "-fms-volatile" "-funwind-tables=2" "-target-cpu" "x86-64" "-tune-cpu" "generic" "-gno-column-info" "-gcodeview" "-debug-info-kind=constructor" "-fdebug-compilation-dir=E:\\repos\\neovim-cfg" "-fcoverage-compilation-dir=E:\\repos\\neovim-cfg" "-resource-dir" "C:\\Program Files\\LLVM\\lib\\clang\\22" "-internal-isystem" "C:\\Program Files\\LLVM\\lib\\clang\\22\\include" "-internal-isystem" "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\include" "-internal-isystem" "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\VS\\include" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\10\\include\\10.0.26100.0\\ucrt" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\10\\\\include\\10.0.26100.0\\\\um" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\10\\\\include\\10.0.26100.0\\\\shared" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\10\\\\include\\10.0.26100.0\\\\winrt" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\10\\\\include\\10.0.26100.0\\\\cppwinrt" "-internal-isystem" "C:\\Program Files (x86)\\Windows Kits\\NETFXSDK\\4.6.1\\include\\um" "-internal-isystem" "G:\\Program Files\\NAG\\DC33\\dcw6i33nal\\include" "-fdeprecated-macro" "-ferror-limit" "19" "-fno-use-cxa-atexit" "-fms-extensions" "-fms-compatibility" "-fms-compatibility-version=19.44.35227" "-std=c++14" "-fskip-odr-check-in-gmf" "-fdelayed-template-parsing" "-fcxx-exceptions" "-fexceptions" "-vectorize-loops" "-vectorize-slp" "-faddrsig" "-x" "c++"
	.byte	242
	.byte	241
	.addrsig
