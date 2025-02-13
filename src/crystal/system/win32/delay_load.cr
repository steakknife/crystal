require "c/delayimp"

lib LibC
  $image_base = __ImageBase : IMAGE_DOS_HEADER
end

private macro p_from_rva(rva)
  pointerof(LibC.image_base).as(UInt8*) + {{ rva }}
end

private macro print_error(format, *args)
  {% if args.empty? %}
    %str = {{ format }}
    LibC.WriteFile(LibC.GetStdHandle(LibC::STD_ERROR_HANDLE), %str, %str.bytesize, out _, nil)
  {% else %}
    %buf = uninitialized LibC::CHAR[1024]
    %args = uninitialized Void*[{{ args.size }}]
    {% for arg, i in args %}
      %args[{{ i }}] = ({{ arg }}).as(Void*)
    {% end %}
    %len = LibC.FormatMessageA(LibC::FORMAT_MESSAGE_FROM_STRING | LibC::FORMAT_MESSAGE_ARGUMENT_ARRAY, {{ format }}, 0, 0, %buf, %buf.size, %args)
    LibC.WriteFile(LibC.GetStdHandle(LibC::STD_ERROR_HANDLE), %buf, %len, out _, nil)
  {% end %}
end

module Crystal::System::DelayLoad
  @[Extern]
  record InternalImgDelayDescr,
    grAttrs : LibC::DWORD,
    szName : LibC::LPSTR,
    phmod : LibC::HMODULE*,
    pIAT : LibC::IMAGE_THUNK_DATA*,
    pINT : LibC::IMAGE_THUNK_DATA*,
    pBoundIAT : LibC::IMAGE_THUNK_DATA*,
    pUnloadIAT : LibC::IMAGE_THUNK_DATA*,
    dwTimeStamp : LibC::DWORD

  @[AlwaysInline]
  def self.pinh_from_image_base(hmod : LibC::HMODULE)
    (hmod.as(UInt8*) + hmod.as(LibC::IMAGE_DOS_HEADER*).value.e_lfanew).as(LibC::IMAGE_NT_HEADERS*)
  end

  @[AlwaysInline]
  def self.interlocked_exchange(atomic : LibC::HMODULE*, value : LibC::HMODULE)
    Atomic::Ops.atomicrmw(:xchg, atomic, value, :sequentially_consistent, false)
  end
end

# This is a port of the default delay-load helper function in the `DelayHlp.cpp`
# file that comes with Microsoft Visual C++, except that all user-defined hooks
# are omitted. It is called every time the program attempts to load a symbol
# from a DLL. For more details see:
# https://learn.microsoft.com/en-us/cpp/build/reference/understanding-the-helper-function
#
# It is available even when the `preview_dll` flag is absent, so that system
# DLLs such as `advapi32.dll` and shards can be delay-loaded in the usual mixed
# static/dynamic builds by passing the appropriate linker flags explicitly.
#
# The delay load helper cannot call functions from the library being loaded, as
# that leads to an infinite recursion. In particular, if `preview_dll` is in
# effect, `Crystal::System.print_error` will not work, because the C runtime
# library DLLs are also delay-loaded and `LibC.snprintf` is unavailable. If you
# want print debugging inside this function, use the `print_error` macro
# instead. Note that its format string is passed to `LibC.FormatMessageA`, which
# uses different conventions from `LibC.printf`.
#
# `kernel32.dll` is the only DLL guaranteed to be available. It cannot be
# delay-loaded and the Crystal compiler excludes it from the linker arguments.
#
# This function does _not_ work with the empty prelude yet!
fun __delayLoadHelper2(pidd : LibC::ImgDelayDescr*, ppfnIATEntry : LibC::FARPROC*) : LibC::FARPROC
  # TODO: support protected delay load? (/GUARD:CF)
  # DloadAcquireSectionWriteAccess

  # Set up some data we use for the hook procs but also useful for our own use
  idd = Crystal::System::DelayLoad::InternalImgDelayDescr.new(
    grAttrs: pidd.value.grAttrs,
    szName: p_from_rva(pidd.value.rvaDLLName).as(LibC::LPSTR),
    phmod: p_from_rva(pidd.value.rvaHmod).as(LibC::HMODULE*),
    pIAT: p_from_rva(pidd.value.rvaIAT).as(LibC::IMAGE_THUNK_DATA*),
    pINT: p_from_rva(pidd.value.rvaINT).as(LibC::IMAGE_THUNK_DATA*),
    pBoundIAT: p_from_rva(pidd.value.rvaBoundIAT).as(LibC::IMAGE_THUNK_DATA*),
    pUnloadIAT: p_from_rva(pidd.value.rvaUnloadIAT).as(LibC::IMAGE_THUNK_DATA*),
    dwTimeStamp: pidd.value.dwTimeStamp,
  )

  dli = LibC::DelayLoadInfo.new(
    cb: sizeof(LibC::DelayLoadInfo),
    pidd: pidd,
    ppfn: ppfnIATEntry,
    szDll: idd.szName,
    dlp: LibC::DelayLoadProc.new,
    hmodCur: LibC::HMODULE.null,
    pfnCur: LibC::FARPROC.null,
    dwLastError: LibC::DWORD.zero,
  )

  if 0 == idd.grAttrs & LibC::DLAttrRva
    # DloadReleaseSectionWriteAccess
    print_error("FATAL: Delay load descriptor does not support RVAs\n")
    LibC.ExitProcess(1)
  end

  hmod = idd.phmod.value

  # Calculate the index for the IAT entry in the import address table
  # N.B. The INT entries are ordered the same as the IAT entries so
  # the calculation can be done on the IAT side.
  iIAT = ppfnIATEntry.as(LibC::IMAGE_THUNK_DATA*) - idd.pIAT
  iINT = iIAT

  pitd = idd.pINT + iINT

  import_by_name = (pitd.value.u1.ordinal & LibC::IMAGE_ORDINAL_FLAG) == 0
  dli.dlp.fImportByName = import_by_name ? 1 : 0

  if import_by_name
    image_import_by_name = p_from_rva(LibC::RVA.new!(pitd.value.u1.addressOfData))
    dli.dlp.union.szProcName = image_import_by_name + offsetof(LibC::IMAGE_IMPORT_BY_NAME, @name)
  else
    dli.dlp.union.dwOrdinal = LibC::DWORD.new!(pitd.value.u1.ordinal & 0xFFFF)
  end

  # Check to see if we need to try to load the library.
  if !hmod
    # note: ANSI variant used here
    unless hmod = LibC.LoadLibraryExA(dli.szDll, nil, 0)
      # DloadReleaseSectionWriteAccess
      print_error("FATAL: Cannot find the DLL named `%1`, exiting\n", dli.szDll)
      LibC.ExitProcess(1)
    end

    # Store the library handle.  If it is already there, we infer
    # that another thread got there first, and we need to do a
    # FreeLibrary() to reduce the refcount
    hmodT = Crystal::System::DelayLoad.interlocked_exchange(idd.phmod, hmod)
    LibC.FreeLibrary(hmod) if hmodT == hmod
  end

  # Go for the procedure now.
  dli.hmodCur = hmod
  if pidd.value.rvaBoundIAT != 0 && pidd.value.dwTimeStamp != 0
    # bound imports exist...check the timestamp from the target image
    pinh = Crystal::System::DelayLoad.pinh_from_image_base(hmod)

    if pinh.value.signature == LibC::IMAGE_NT_SIGNATURE &&
       pinh.value.fileHeader.timeDateStamp == idd.dwTimeStamp &&
       hmod.address == pinh.value.optionalHeader.imageBase
      # Everything is good to go, if we have a decent address
      # in the bound IAT!
      if pfnRet = LibC::FARPROC.new(idd.pBoundIAT[iIAT].u1.function)
        ppfnIATEntry.value = pfnRet
        # DloadReleaseSectionWriteAccess
        return pfnRet
      end
    end
  end

  unless pfnRet = LibC.GetProcAddress(hmod, dli.dlp.union.szProcName)
    # DloadReleaseSectionWriteAccess
    if import_by_name
      print_error("FATAL: Cannot find the symbol named `%1` within `%2`, exiting\n", dli.dlp.union.szProcName, dli.szDll)
    else
      print_error("FATAL: Cannot find the symbol with the ordinal #%1!u! within `%2`, exiting\n", Pointer(Void).new(dli.dlp.union.dwOrdinal), dli.szDll)
    end
    LibC.ExitProcess(1)
  end

  ppfnIATEntry.value = pfnRet
  # DloadReleaseSectionWriteAccess
  pfnRet
end
