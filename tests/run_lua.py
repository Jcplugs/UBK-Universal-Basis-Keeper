import ctypes, pathlib, sys
lib=ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype=ctypes.c_void_p
lib.luaL_openlibs.argtypes=[ctypes.c_void_p]
lib.luaL_loadfilex.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lib.luaL_loadstring.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
lib.lua_pcallk.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_longlong,ctypes.c_void_p]
lib.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p];lib.lua_tolstring.restype=ctypes.c_char_p
lib.lua_close.argtypes=[ctypes.c_void_p]
root=pathlib.Path(__file__).resolve().parents[1]/'addon/Interface/AddOns/UniversalBasisKeeper'
def run(data=None,file=None,execute=True):
 state=lib.luaL_newstate();lib.luaL_openlibs(state)
 status=lib.luaL_loadstring(state,data.encode()) if data is not None else lib.luaL_loadfilex(state,str(file).encode(),None)
 if not status and execute: status=lib.lua_pcallk(state,0,-1,0,0,None)
 if status: raise RuntimeError(lib.lua_tolstring(state,-1,None).decode())
 lib.lua_close(state)
for path in sorted(root.glob('*.lua')):
 run(file=path,execute=False)
print('PASS: syntax',len(list(root.glob('*.lua'))),'Lua files')
tests=[pathlib.Path(value) for value in sys.argv[1:]] if len(sys.argv)>1 else sorted(pathlib.Path(__file__).resolve().parent.glob('*_test.lua'))
for path in tests:
 print('RUN:',path.name,flush=True)
 run(data='ADDON_ROOT = '+repr(str(root))+'\n'+path.read_text())
