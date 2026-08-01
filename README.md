# gear

**An execution machine.** The libraries were there; the machine that advances time was not.

```
darkcore  = the shared vocabulary of verbs   (one Effect type; side effects become data)
zeolite   = the shared shape of nouns        (types at the boundary)
berylx    = the grammar of connection        (Task : Lay -> Result[Lay])
gear      = the thing that actually runs     (this repository)
```

Five parts, no more: **Clock, Admission, Executor, Journal, Receipt.**

The point is not verification. The point is that anything can be connected to anything:
every external system becomes an `Effect` behind a port adapter, every program is a berylx
task composition, the journal is the only source of truth, and a UI is just a view of it.
Determinism and after-the-fact explainability fall out of that arrangement for free.

Specification: `spec-system/pins/domains/gear.spec` (source of truth).
