As of now, the emulator hangs after:
```
[    0.057528] devtmpfs: initialized
```
At a high level, it's hanging in `drivers/base/init.c` in:
```
of_core_init.c
 ╰__of_attach_node_sysfs
  ╰__of_add_property_sysfs
   ╰sysfs_create_bin_file
    ╰sysfs_add_bin_file_mode_ns
     ╰__kernfs_create_file (fs/kernfs/dir.c)
      ╰kernfs_activate
       ╰down_write
        ╰LOCK_CONTENDED(sem, __down_write_trylock, __down_write);
         ╰__down_write_common
```

In `__down_write_common`:
```c
  if (unlikely(!rwsem_write_trylock(sem))) {
    if (IS_ERR(rwsem_down_write_slowpath(sem, state))) {
      return -EINTR;
    }
  }
```
The first condition is supposed to succeed every time. Checked it using mini-rv32ima.
But in our case, the condition will fail (not every time) and then we lock on the
call to slowpath.

Logs of an instrumented kernel:
```
[    0.622218] __of_add_property_sysfs 4
[    0.622979] LOCK_CONTENDED 2
[    0.623673] __of_add_property_sysfs 5
[    0.624370] sysfs_create_bin_file 1
[    0.625318] sysfs_create_bin_file 2
[    0.626007] sysfs_create_bin_file 3
[    0.626712] sysfs_add_bin_file_mode_ns 1
[    0.627479] sysfs_add_bin_file_mode_ns 2
[    0.628215] sysfs_add_bin_file_mode_ns 3
[    0.628973] __kernfs_create_file 1
[    0.629761] __kernfs_create_file 2
[    0.630454] __kernfs_create_file 3
[    0.631153] __kernfs_create_file 4
[    0.631849] __kernfs_create_file 5
[    0.632556] down_write 1
[    0.633175] down_write 2
[    0.633761] down_write 3
[    0.634361] LOCK_CONTENDED 2
[    0.635013] __down_write_common 1
[    0.635979] atomic_long_try_cmpxchg_acquire
[    0.636768] arch_atomic_long_try_cmpxchg_acquire
[    0.637603] arch_atomic_try_cmpxchg_acquire 1
[    0.638412] __down_write_common 2
[    0.639088] atomic_long_try_cmpxchg_acquire
[    0.639839] arch_atomic_long_try_cmpxchg_acquire
[    0.640616] arch_atomic_try_cmpxchg_acquire 1
[    0.641358] down_write 4
[    0.641949] __kernfs_create_file 12
[    0.642627] __kernfs_create_file 12.1
[    0.643372] kernfs_activate 1
[    0.643998] down_write 1
[    0.644557] down_write 2
[    0.645126] down_write 3
[    0.645904] LOCK_CONTENDED 2
[    0.646504] __down_write_common 1
[    0.647142] atomic_long_try_cmpxchg_acquire
[    0.647900] arch_atomic_long_try_cmpxchg_acquire
[    0.648682] arch_atomic_try_cmpxchg_acquire 1
[    0.649410] __down_write_common 2
```

It is unclear why the condition fails. In `__cmpxchg_acquire` (arch/riscv/include/asm/cmpxchg.h:223)
a `bnez` here will branch and we end up taking the slow path that hangs. Why the branch
is taken is unclear.

I tried to compare memread/memwrite with mini-rv32ima project but due to difference
in timing it ends up diverging. Other diff shows before that but are all related
to the DTB not being exactly in the same place in memory.

I have reviewed and fix a few bugs in the handling on interruption which were
mainly due to the disperse nature of the documentation related to interruption/exception
on RISC-V. I can't guarantee that the implementation is totally compliant though
because I might have missed something in the hundred pages of documentation.

I have reviewed the implementation of LR.W and SC.W and compared it with other
emulators without coming out with any meaningful differences (mini-rv32ima is actually
worst in terms of compliance but it does not seem to affect the result).

All riscv-tests unit tests pass (except the one that needs debug mode).
