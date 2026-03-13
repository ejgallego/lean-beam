import Lean

namespace RunAtCli.Broker

structure BrokerConfig where
  root : System.FilePath
  leanCmd? : Option String := none
  leanPlugin? : Option System.FilePath := none
  rocqCmd? : Option String := none
  deriving Inhabited, Repr

end RunAtCli.Broker
