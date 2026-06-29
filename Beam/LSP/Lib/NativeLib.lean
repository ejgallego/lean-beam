import Lake.Util.NativeLib

namespace Beam.LSP.Lib

/-
Shared-library naming for the standalone Beam LSP plugin.

Runtime, installer, and test harness code all need the same plugin artifact path, so this helper is
shared even though it is not request logic.
-/

def pluginSharedLibName : String :=
  Lake.nameToSharedLib "beam_Beam_LSP"

def pluginSharedLibPath (dir : System.FilePath) : System.FilePath :=
  dir / pluginSharedLibName

end Beam.LSP.Lib
