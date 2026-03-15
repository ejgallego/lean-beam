/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol

namespace Beam.Broker.Backend.Shared

def goalModeValue (mode? : Option GoalMode) : String :=
  match mode? with
  | some mode => mode.key
  | none => GoalMode.after.key

def goalPpFormatValue (ppFormat? : Option GoalPpFormat) : String :=
  match ppFormat? with
  | some format => format.key
  | none => GoalPpFormat.str.key

end Beam.Broker.Backend.Shared
