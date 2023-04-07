// RUN: mlir-hlo-opt %s --split-input-file --allow-unregistered-dialect \
// RUN:     --hlo-deallocate | \
// RUN: FileCheck %s

// RUN: mlir-hlo-opt %s --split-input-file --allow-unregistered-dialect \
// RUN:     --hlo-deallocate --hlo-deallocation-simplification | \
// RUN: FileCheck %s --check-prefix=CHECK-SIMPLE

func.func @loop_nested_alloc(
    %lb: index, %ub: index, %step: index,
    %buf: memref<2xf32>, %res: memref<2xf32>) {
  %0 = memref.alloc() : memref<2xf32>
  %1 = scf.for %i = %lb to %ub step %step
      iter_args(%iterBuf = %buf) -> memref<2xf32> {
    %2 = scf.for %i2 = %lb to %ub step %step
        iter_args(%iterBuf2 = %iterBuf) -> memref<2xf32> {
      %3 = memref.alloc() : memref<2xf32>
      %4 = arith.cmpi eq, %i, %ub : index
      %5 = scf.if %4 -> (memref<2xf32>) {
        %6 = memref.alloc() : memref<2xf32>
        scf.yield %6 : memref<2xf32>
      } else {
        scf.yield %iterBuf2 : memref<2xf32>
      }
      scf.yield %5 : memref<2xf32>
    }
    scf.yield %2 : memref<2xf32>
  }
  memref.copy %1, %res : memref<2xf32> to memref<2xf32>
  return
}

// CHECK-LABEL: func @loop_nested_alloc
// CHECK-SAME:     %[[ARG3:[a-z0-9]*]]: memref<2xf32>, %[[OUT:.*]]: memref<2xf32>)
// CHECK: %[[ALLOC:.*]] = memref.alloc() : memref<2xf32>
// CHECK: %[[ALLOC_OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK: deallocation.retain() of(%[[ALLOC_OWNED]])
// CHECK: %[[ARG3_UNOWNED:.*]] = deallocation.null
// CHECK: %[[FOR1:.*]]:2 = scf.for {{.*}}iter_args(%[[A:.*]] = %[[ARG3]], %[[A_OWNERSHIP:.*]] = %[[ARG3_UNOWNED]])
// CHECK:   %[[FOR2:.*]]:2 = scf.for {{.*}} iter_args(%[[B:.*]] = %[[A]], %[[B_OWNERSHIP:.*]] = %[[A_OWNERSHIP]])
// CHECK:     %[[ALLOC2:.*]] = memref.alloc() : memref<2xf32>
// CHECK:     %[[ALLOC2_OWNED:.*]] = deallocation.own %[[ALLOC2]]
// CHECK:     deallocation.retain() of(%[[ALLOC2_OWNED]])
// CHECK:     %[[IF:.*]]:2 = scf.if
// CHECK:       %[[ALLOC3:.*]] = memref.alloc() : memref<2xf32>
// CHECK:       %[[ALLOC3_OWNED:.*]] = deallocation.own %[[ALLOC3]]
// CHECK:       scf.yield %[[ALLOC3]], %[[ALLOC3_OWNED]]
// CHECK:     } else {
// CHECK:       %[[NULL:.*]] = deallocation.retain(%[[B]]) of()
// CHECK:       scf.yield %[[B]], %[[NULL]]
// CHECK:     }
// CHECK:     %[[RETAINED_IF:.*]] = deallocation.retain(%[[IF]]#0) of(%[[B_OWNERSHIP]], %[[IF]]#1)
// CHECK:     scf.yield %[[IF]]#0, %[[RETAINED_IF]]
// CHECK:   }
// CHECK:   scf.yield %[[FOR2]]#0, %[[FOR2]]#1
// CHECK: }
// CHECK: memref.copy %[[FOR1]]#0, %[[OUT]]
// CHECK: deallocation.retain() of(%[[FOR1]]#1)
// CHECK: return

// -----

func.func @nested_if() -> (memref<2xf32>, memref<2xf32>) {
  %alloc_0 = memref.alloc() : memref<2xf32>
  %alloc_1 = memref.alloc() : memref<2xf32>
  %a = "test.condition"() : () -> i1
  %0 = scf.if %a -> (memref<2xf32>) {
    %2 = memref.alloc() : memref<2xf32>
    scf.yield %2 : memref<2xf32>
  } else {
    %b = "test.condition"() : () -> i1
    %3 = scf.if %b -> (memref<2xf32>) {
      scf.yield %alloc_0 : memref<2xf32>
    } else {
      scf.yield %alloc_1 : memref<2xf32>
    }
    scf.yield %3 : memref<2xf32>
  }
  return %alloc_0, %0 : memref<2xf32>, memref<2xf32>
}

// CHECK-LABEL: func @nested_if
// CHECK:       %[[ALLOC0:.*]] = memref.alloc()
// CHECK:       %[[ALLOC0_OWNED:.*]] = deallocation.own %[[ALLOC0]]
// CHECK:       %[[ALLOC1:.*]] = memref.alloc()
// CHECK:       %[[ALLOC1_OWNED:.*]] = deallocation.own %[[ALLOC1]]
// CHECK:       %[[IF1:.*]]:2 = scf.if
// CHECK-NEXT:    %[[ALLOC2:.*]] = memref.alloc()
// CHECK-NEXT:    %[[ALLOC2_OWNED:.*]] = deallocation.own %[[ALLOC2]]
// CHECK-NEXT:    scf.yield %[[ALLOC2]], %[[ALLOC2_OWNED]]
// CHECK-NEXT:  } else {
// CHECK:         %[[IF2:.*]]:2 = scf.if
// CHECK-NEXT:      %[[NULL:.*]] = deallocation.retain(%[[ALLOC0]]) of()
// CHECK-NEXT:      scf.yield %[[ALLOC0]], %[[NULL]]
// CHECK-NEXT:    } else {
// CHECK-NEXT:      %[[NULL:.*]] = deallocation.retain(%[[ALLOC1]]) of()
// CHECK-NEXT:      scf.yield %[[ALLOC1]], %[[NULL]]
// CHECK-NEXT:    }
// CHECK-NEXT:    scf.yield %[[IF2]]#0, %[[IF2]]#1
// CHECK-NEXT:  }
// CHECK-NEXT:  %[[RETAINED:.*]]:2 = deallocation.retain(%[[ALLOC0]], %[[IF1]]#0) of(%[[ALLOC0_OWNED]], %[[ALLOC1_OWNED]], %[[IF1]]#1)
// CHECK-NEXT:  return %[[ALLOC0]], %[[IF1]]#0, %[[RETAINED]]#0, %[[RETAINED]]#1 : memref<2xf32>, memref<2xf32>, !deallocation.ownership, !deallocation.ownership

// -----

func.func @while(%arg0: index) -> (memref<?xf32>, memref<?xf32>, memref<?xf32>) {
  %a = memref.alloc(%arg0) : memref<?xf32>
  %w:3 = scf.while (%arg1 = %a, %arg2 = %a, %arg3 = %a) : (memref<?xf32>, memref<?xf32>, memref<?xf32>)
      -> (memref<?xf32>, memref<?xf32>, memref<?xf32>) {
    %0 = "test.make_condition"() : () -> i1
    scf.condition(%0) %arg1, %arg2, %arg3 : memref<?xf32>, memref<?xf32>, memref<?xf32>
  } do {
  ^bb0(%arg1: memref<?xf32>, %arg2: memref<?xf32>, %arg3: memref<?xf32>):
    %b = memref.alloc(%arg0) : memref<?xf32>
    %q = memref.alloc(%arg0) : memref<?xf32>
    scf.yield %q, %b, %arg2: memref<?xf32>, memref<?xf32>, memref<?xf32>
  }
  return %w#0, %w#1, %w#2 : memref<?xf32>, memref<?xf32>, memref<?xf32>
}

// CHECK-LABEL: func @while(
// CHECK-SAME:      %[[ARG0:.*]]:
// CHECK-NEXT:    %[[ALLOC:.*]] = memref.alloc(%arg0) : memref<?xf32>
// CHECK-NEXT:    %[[ALLOC_OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK-NEXT:    %[[NULL1:.*]] = deallocation.null
// CHECK-NEXT:    %[[NULL2:.*]] = deallocation.null
// CHECK-NEXT:    %[[WHILE:.*]]:6 = scf.while (%[[A:[a-z0-9]*]] = %[[ALLOC]], %[[B:[a-z0-9]*]] = %[[ALLOC]], %[[C:[a-z0-9]*]] = %[[ALLOC]],
// CHECK-SAME:       %[[A_OWNERSHIP:.*]] = %[[ALLOC_OWNED]], %[[B_OWNERSHIP:.*]] = %[[NULL1]], %[[C_OWNERSHIP:.*]] = %[[NULL2]])
// CHECK:            scf.condition{{.*}} %[[A]], %[[B]], %[[C]], %[[A_OWNERSHIP]], %[[B_OWNERSHIP]], %[[C_OWNERSHIP]]
// CHECK:         } do {
// CHECK:           deallocation.retain() of(%[[C_OWNERSHIP]])
// CHECK:           deallocation.retain() of(%[[A_OWNERSHIP]])
// CHECK:           %[[ALLOC1:.*]] = memref.alloc(%[[ARG0]])
// CHECK:           %[[ALLOC1_OWNED:.*]] = deallocation.own %[[ALLOC1]]
// CHECK:           %[[ALLOC2:.*]] = memref.alloc(%[[ARG0]])
// CHECK:           %[[ALLOC2_OWNED:.*]] = deallocation.own %[[ALLOC2]]
// CHECK:           scf.yield %[[ALLOC2]], %[[ALLOC1]], %[[B]], %[[ALLOC2_OWNED]], %[[ALLOC1_OWNED]], %[[B_OWNERSHIP]]
// CHECK:         }
// CHECK:         %[[RESULTS_RETAINED:.*]] = deallocation.retain(%[[WHILE]]#0, %[[WHILE]]#1, %[[WHILE]]#2)
// CHECK-SAME:      of(%[[WHILE]]#3, %[[WHILE]]#4, %[[WHILE]]#5)
// CHECK:         return %[[WHILE]]#0, %[[WHILE]]#1, %[[WHILE]]#2

// -----

func.func @if_without_else() {
  %cond = "test.make_condition"() : () -> i1
  scf.if %cond {
    %x = memref.alloc() : memref<2xf32>
    "test.use"(%x) : (memref<2xf32>) -> ()
    scf.yield
  }
  return
}

// CHECK-LABEL: @if_without_else
// CHECK: scf.if
// CHECK-NEXT: %[[ALLOC:.*]] = memref.alloc
// CHECK-NEXT: %[[ALLOC_OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK-NEXT: test.use
// CHECK-NEXT: deallocation.retain() of(%[[ALLOC_OWNED]])

// CHECK-SIMPLE-LABEL: @if_without_else
// CHECK-SIMPLE:       scf.if
// CHECK-SIMPLE-NEXT:    memref.alloc
// CHECK-SIMPLE-NEXT:    test.use
// CHECK-SIMPLE-NEXT:    memref.dealloc

// -----

func.func @yield_same_alloc_twice() {
  %alloc = memref.alloc() : memref<f32>
  scf.while (%a = %alloc, %b = %alloc) : (memref<f32>, memref<f32>) -> () {
    %cond = "test.make_condition"() : () -> i1
    scf.condition(%cond)
  } do {
  ^bb0():
    scf.yield %alloc, %alloc : memref<f32>, memref<f32>
  }
  return
}

// CHECK-LABEL: @yield_same_alloc_twice
// CHECK-NEXT: %[[ALLOC:.*]] = memref.alloc
// CHECK-NEXT: %[[ALLOC_OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK-NEXT: %[[NULL1:.*]] = deallocation.null
// CHECK-NEXT: %[[NULL2:.*]] = deallocation.null
// CHECK: scf.while
// CHECK-SAME: %[[ALLOC]]
// CHECK-SAME: %[[ALLOC]]
// CHECK-SAME: %[[NULL1]]
// CHECK-SAME: %[[NULL2]]
// CHECK: } do {
// CHECK-NEXT: %[[NULL:.*]] = deallocation.null
// CHECK-NEXT: %[[RETAIN:.*]]:2 = deallocation.retain(%[[ALLOC]], %[[ALLOC]]) of()
// CHECK-NEXT: scf.yield %[[ALLOC]], %[[ALLOC]], %[[RETAIN]]#1, %[[NULL]]

// -----

func.func @yield_derived(%lb: index, %ub: index, %step: index) {
  %0 = memref.alloc() : memref<2xi32>
  %1 = scf.for %i2 = %lb to %ub step %step iter_args(%arg0 = %0) -> memref<2xi32> {
    %2 = memref.alloc() : memref<2xi32>
    %3 = "test.someop"(%2) : (memref<2xi32>) -> memref<1xi32>
    %4 = "test.someop"(%3) : (memref<1xi32>) -> memref<2xi32>
    scf.yield %4 : memref<2xi32>
  }
  "test.use"(%1) : (memref<2xi32>) -> ()
  return
}

// CHECK-LABEL: @yield_derived
// CHECK-NEXT:  memref.alloc
// CHECK-NEXT:  deallocation.own
// CHECK-NEXT:  scf.for
// CHECK-NEXT:    deallocation.retain()
// CHECK-NEXT:    %[[ALLOC:.*]] = memref.alloc
// CHECK-NEXT:    %[[ALLOC_OWNED:.*]] = deallocation.own
// CHECK-NEXT:    "test.someop"
// CHECK-NEXT:    %[[RESULT:.*]] = "test.someop"
// CHECK-NEXT:    scf.yield %[[RESULT]], %[[ALLOC_OWNED]]
// CHECK-NEXT:  }
// CHECK-NEXT:  test.use
// CHECK-NEXT:  retain

// CHECK-SIMPLE-LABEL: @yield_derived
// CHECK-SIMPLE:       test.use
// CHECK-SIMPLE-NEXT:  memref.dealloc

// -----

func.func @unknown_op() {
  %c0 = arith.constant 0 : index
  %c512 = arith.constant 512 : index
  %c1 = arith.constant 1 : index
  %c8 = arith.constant 8 : index
  scf.parallel (%arg3, %arg4) = (%c0, %c0) to (%c512, %c512) step (%c1, %c8) {
    %alloc_14 = memref.alloc() {alignment = 64 : i64} : memref<512x512xf32>
    "test.use"(%alloc_14) : (memref<512x512xf32>) -> ()
    scf.yield
  }
  return
}

// CHECK-SIMPLE-LABEL: @unknown_op
// CHECK-SIMPLE: scf.parallel
// CHECK-SIMPLE-NEXT: memref.alloc()
// TODO(jreiffers): Remove the `own` op in simplification.
// CHECK-SIMPLE: test.use
// CHECK-SIMPLE-NEXT: memref.dealloc

// -----

func.func @unconditional_realloc(%init: index, %new: index) {
  %alloc = memref.alloc(%init) : memref<?xi32>
  "test.use"(%alloc) : (memref<?xi32>) -> ()
  %realloc = memref.realloc %alloc(%new) : memref<?xi32> to memref<?xi32>
  "test.use"(%realloc) : (memref<?xi32>) -> ()
  return
}

// CHECK-LABEL: @unconditional_realloc
// CHECK-NEXT: memref.alloc
// CHECK-NEXT: deallocation.own
// CHECK-NEXT: test.use
// CHECK-NEXT: %[[REALLOC:.*]] = memref.realloc
// CHECK-NEXT: %[[OWNED:.*]] = deallocation.own %[[REALLOC]]
// CHECK-NEXT: test.use
// CHECK-NEXT: deallocation.retain() of(%[[OWNED]])
// CHECK-NEXT: return

// CHECK-SIMPLE-LABEL: @unconditional_realloc
// CHECK-SIMPLE-NEXT: memref.alloc
// CHECK-SIMPLE-NEXT: test.use
// CHECK-SIMPLE-NEXT: %[[REALLOC:.*]] = memref.realloc
// CHECK-SIMPLE-NEXT: test.use
// CHECK-SIMPLE-NEXT: memref.dealloc %[[REALLOC]]

// -----

func.func @realloc_in_if(%init: index) {
  %alloc = memref.alloc(%init) : memref<?xi32>
  %cond = "test.make_condition"() : () -> (i1)
  %new_alloc = scf.if %cond -> memref<?xi32> {
    %new_size = "test.make_index"() : () -> (index)
    %ret = memref.realloc %alloc(%new_size) : memref<?xi32> to memref<?xi32>
    scf.yield %ret : memref<?xi32>
  } else {
    scf.yield %alloc: memref<?xi32>
  }
  "test.use"(%new_alloc) : (memref<?xi32>) -> ()
  return
}

// CHECK-LABEL: @realloc_in_if
// CHECK-NEXT: %[[ALLOC:.*]] = memref.alloc
// CHECK-NEXT: %[[OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK-NEXT: test.make_condition
// CHECK-NEXT: %[[NEW_ALLOC:.*]]:2 = scf.if
// CHECK-NEXT:   test.make_index
// CHECK-NEXT:   %[[REALLOC:.*]] = memref.realloc %[[ALLOC]]
// CHECK-NEXT:   %[[REALLOC_OWNED:.*]] = deallocation.own %[[REALLOC]]
// CHECK-NEXT:   scf.yield %[[REALLOC]], %[[REALLOC_OWNED]]
// CHECK-NEXT: } else {
// CHECK-NEXT:   deallocation.retain(%[[ALLOC]]) of()
// CHECK-NEXT:   scf.yield %[[ALLOC]], %[[OWNED]]
// CHECK-NEXT: }
// CHECK-NEXT: "test.use"(%[[NEW_ALLOC]]#0)
// CHECK-NEXT: deallocation.retain() of(%[[NEW_ALLOC]]#1)
// CHECK-NEXT: return

// -----

func.func @realloc_in_if_strange_but_ok(%size: index, %cond: i1) {
  %alloc = memref.alloc(%size) : memref<?xi32>
  scf.if %cond -> memref<?xi32> {
    %realloc = memref.realloc %alloc(%size) : memref<?xi32> to memref<?xi32>
    %new = memref.alloc(%size) : memref<?xi32>
    scf.yield %new : memref<?xi32>
  } else {
    "test.dummy"() : () -> ()
    scf.yield %alloc : memref<?xi32>
  }
  return
}

// CHECK-LABEL: @realloc_in_if_strange_but_ok
// CHECK-NEXT: %[[ALLOC:.*]] = memref.alloc
// CHECK-NEXT: %[[OWNED:.*]] = deallocation.own %[[ALLOC]]
// CHECK-NOT: deallocation.retain() of(%[[OWNED]])

// -----

func.func @realloc_in_loop(%size: index, %lb: index, %ub: index, %step: index) {
  %alloc = memref.alloc(%size) : memref<?xi32>
  scf.for %i = %lb to %ub step %step iter_args(%arg0 = %alloc) -> memref<?xi32> {
    %cond = "test.make_condition"() : () -> i1
    %new = scf.if %cond -> memref<?xi32> {
      %realloc = memref.realloc %arg0(%size) : memref<?xi32> to memref<?xi32>
      scf.yield %realloc : memref<?xi32>
    } else {
      scf.yield %arg0 : memref<?xi32>
    }
    scf.yield %new : memref<?xi32>
  }
  return
}

// CHECK-LABEL: @realloc_in_loop
// CHECK-NEXT: memref.alloc
// CHECK-NEXT: %[[OWNED:.*]] = deallocation.own
// CHECK-NEXT: %[[FOR:.*]]:2 = scf.for
// CHECK:        %[[IF:.*]]:2 = scf.if
// CHECK:        scf.yield %[[IF]]#0, %[[IF]]#1
// CHECK-NEXT: }
// CHECK-NEXT: deallocation.retain() of(%[[FOR]]#1)
// CHECK-NEXT: return

// -----

func.func @dealloc() {
  %alloc = memref.alloc() : memref<i32>
  "test.use"(%alloc) : (memref<i32>) -> ()
  memref.dealloc %alloc: memref<i32>
  return
}

// CHECK-LABEL: @dealloc
// CHECK-SIMPLE-LABEL: @dealloc
// CHECK-SIMPLE-NEXT: memref.alloc
// CHECK-SIMPLE-NEXT: test.use
// CHECK-SIMPLE-NEXT: memref.dealloc
// CHECK-SIMPLE-NEXT: return

// -----

func.func @dealloc_in_loop(%lb: index, %ub: index, %step: index) {
  scf.for %i = %lb to %ub step %step {
    %alloc = memref.alloc() : memref<i32>
    "test.use"(%alloc) : (memref<i32>) -> ()
    memref.dealloc %alloc: memref<i32>
  }
  return
}

// CHECK-LABEL: @dealloc_in_loop
// CHECK-SIMPLE-LABEL: @dealloc_in_loop
// CHECK-SIMPLE-NEXT: scf.for
// CHECK-SIMPLE-NEXT:   memref.alloc
// CHECK-SIMPLE-NEXT:   test.use
// CHECK-SIMPLE-NEXT:   memref.dealloc
// CHECK-SIMPLE-NEXT: }
// CHECK-SIMPLE-NEXT: return

// -----

func.func @dealloc_around_loop(%lb: index, %ub: index, %step: index) {
  %alloc = memref.alloc() : memref<i32>
  scf.for %i = %lb to %ub step %step {
    "test.use"(%alloc) : (memref<i32>) -> ()
  }
  memref.dealloc %alloc: memref<i32>
  return
}

// CHECK-LABEL: @dealloc_around_loop
// CHECK-SIMPLE-LABEL: @dealloc_around_loop
// CHECK-SIMPLE-NEXT: memref.alloc
// CHECK-SIMPLE-NEXT: scf.for
// CHECK-SIMPLE-NEXT:   test.use
// CHECK-SIMPLE-NEXT: }
// CHECK-SIMPLE-NEXT: memref.dealloc
// CHECK-SIMPLE-NEXT: return

// -----

func.func @memory_effect_no_free_or_alloc() {
  %alloc = memref.alloc() : memref<i32>
  %expand_shape = memref.expand_shape %alloc [] : memref<i32> into memref<1x1xi32>
  "test.use"(%expand_shape) : (memref<1x1xi32>) -> ()
  return
}

// CHECK-LABEL: @memory_effect_no_free_or_alloc
// CHECK-NEXT: memref.alloc
// CHECK-NEXT: deallocation.own
// CHECK-NEXT: memref.expand_shape
// CHECK-NEXT: test.use
// CHECK-NEXT: deallocation.retain

// -----

func.func @id(%arg0: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  return %arg0 : memref<1x2x3xf32>
}

func.func @user(%arg0: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = call @id(%arg0) : (memref<1x2x3xf32>) -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK: @id(%[[ARG0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[RETAIN:.*]] = deallocation.retain(%[[ARG0]]) of()
// CHECK:   return %[[ARG0]], %[[RETAIN]]

// CHECK: @user(%[[ARG0_0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[OWNERSHIP:.*]]:2 = call @id(%[[ARG0_0]])
// CHECK:   return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @id_select(%arg0: i1, %arg1: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = arith.select %arg0, %arg1, %arg1 : memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

func.func @user(%arg0: i1, %arg1: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = call @id_select(%arg0, %arg1) : (i1, memref<1x2x3xf32>) -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK: @id_select(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[SELECT:.*]] = arith.select %[[ARG0]], %[[ARG1]], %[[ARG1]]
// CHECK:   %[[RETAIN:.*]] = deallocation.retain(%[[SELECT]]) of()
// CHECK:   return %[[SELECT]], %[[RETAIN]]

// CHECK: @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[OWNERSHIP:.*]]:2 = call @id_select(%[[ARG0_0]], %[[ARG1_0]])
// CHECK:   return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @ite(%arg0: i1, %arg1: memref<1x2x3xf32>, %arg2: memref<1x2x3xf32>)
    -> memref<1x2x3xf32> {
  %0 = scf.if %arg0 -> (memref<1x2x3xf32>) {
    scf.yield %arg1 : memref<1x2x3xf32>
  } else {
    scf.yield %arg2 : memref<1x2x3xf32>
  }
  return %0 : memref<1x2x3xf32>
}

func.func @user(%arg0: i1, %arg1: memref<1x2x3xf32>, %arg2: memref<1x2x3xf32>)
    -> memref<1x2x3xf32> {
  %0 = call @ite(%arg0, %arg1, %arg2)
      : (i1, memref<1x2x3xf32>, memref<1x2x3xf32>) -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK: @ite(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>, %[[ARG2:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[IF:.*]]:2 = scf.if %[[ARG0]]
// CHECK:     %[[RETAIN:.*]] = deallocation.retain(%[[ARG1]]) of()
// CHECK:     scf.yield %[[ARG1]], %[[RETAIN]]
// CHECK:   else
// CHECK:     %[[RETAIN_0:.*]] = deallocation.retain(%[[ARG2]]) of()
// CHECK:     scf.yield %[[ARG2]], %[[RETAIN_0]]
// CHECK:   return %[[IF]]#0, %[[IF]]#1

// CHECK: @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>, %[[ARG2_0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[OWNERSHIP:.*]]:2 = call @ite(%[[ARG0_0]], %[[ARG1_0]], %[[ARG2_0]])
// CHECK:   return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @ite_select(%arg0: i1, %arg1: memref<1x2x3xf32>,
    %arg2: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = arith.select %arg0, %arg1, %arg2 : memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

func.func @user(%arg0: i1, %arg1: memref<1x2x3xf32>, %arg2: memref<1x2x3xf32>)
    -> memref<1x2x3xf32> {
  %0 = call @ite_select(%arg0, %arg1, %arg2)
      : (i1, memref<1x2x3xf32>, memref<1x2x3xf32>) -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK: @ite_select(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>, %[[ARG2:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[SELECT:.*]] = arith.select %[[ARG0]], %[[ARG1]], %[[ARG2]]
// CHECK:   %[[RETAIN:.*]] = deallocation.retain(%[[SELECT]]) of()
// CHECK:   return %[[SELECT]], %[[RETAIN]]

// CHECK: @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>, %[[ARG2_0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[OWNERSHIP:.*]]:2 = call @ite_select(%[[ARG0_0]], %[[ARG1_0]], %[[ARG2_0]])
// CHECK:   return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @may_reuse(%arg0: i1, %arg1: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = scf.if %arg0 -> (memref<1x2x3xf32>) {
    scf.yield %arg1 : memref<1x2x3xf32>
  } else {
    %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
    scf.yield %alloc : memref<1x2x3xf32>
  }
  return %0 : memref<1x2x3xf32>
}

func.func @user(%arg0: i1, %arg1: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = call @may_reuse(%arg0, %arg1) : (i1, memref<1x2x3xf32>)
      -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK: @may_reuse(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[IF:.*]]:2 = scf.if %[[ARG0]]
// CHECK:     %[[RETAIN:.*]] = deallocation.retain(%[[ARG1]]) of()
// CHECK:     scf.yield %[[ARG1]], %[[RETAIN]]
// CHECK:   else
// CHECK:     %[[ALLOC:.*]] = memref.alloc
// CHECK:     %[[OWN:.*]] = deallocation.own %[[ALLOC]]
// CHECK:     scf.yield %[[ALLOC]], %[[OWN]]
// CHECK:   return %[[IF]]#0, %[[IF]]#1

// CHECK: @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>)
// CHECK:   %[[OWNERSHIP:.*]]:2 = call @may_reuse(%[[ARG0_0]], %[[ARG1_0]])
// CHECK:   return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @insert(%arg0: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index
  %cst = arith.constant 7.000000e+00 : f32
  memref.store %cst, %arg0[%c0, %c1, %c1] : memref<1x2x3xf32>
  return %arg0 : memref<1x2x3xf32>
}

func.func @user(%arg0: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = call @insert(%arg0) : (memref<1x2x3xf32>) -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK:     @insert(%[[ARG0:.*]]: memref<1x2x3xf32>)
// CHECK-DAG:   %[[C0:.*]] = arith.constant 0
// CHECK-DAG:   %[[C1:.*]] = arith.constant 1
// CHECK-DAG:   %[[CST:.*]] = arith.constant 7.0
// CHECK:       memref.store %[[CST]], %[[ARG0]][%[[C0]], %[[C1]], %[[C1]]]
// CHECK:       %[[RETAIN:.*]] = deallocation.retain(%[[ARG0]]) of()
// CHECK:       return %[[ARG0]], %[[RETAIN]]

// CHECK:     @user(%[[ARG0_0:.*]]: memref<1x2x3xf32>)
// CHECK:       %[[OWNERSHIP:.*]]:2 = call @insert(%[[ARG0_0]])
// CHECK:       return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1

// -----

func.func @ite_no_yielded_buffers(%pred: i1) {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index
  %cst = arith.constant 7.000000e+00 : f32
  %outer_alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
  scf.if %pred {
    %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
    memref.store %cst, %alloc[%c0, %c1, %c1] : memref<1x2x3xf32>
    scf.yield
  } else {
    memref.store %cst, %outer_alloc[%c0, %c1, %c1] : memref<1x2x3xf32>
    scf.yield
  }
  return
}

func.func @user(%arg0: i1) {
  call @ite_no_yielded_buffers(%arg0) : (i1) -> ()
  return
}

// CHECK:     @ite_no_yielded_buffers(%[[ARG0:.*]]: i1)
// CHECK-DAG:   %[[C0:.*]] = arith.constant 0
// CHECK-DAG:   %[[C1:.*]] = arith.constant 1
// CHECK-DAG:   %[[CST:.*]] = arith.constant 7.0
// CHECK:       %[[ALLOC:.*]] = memref.alloc
// CHECK:       %[[OWN:.*]] = deallocation.own %[[ALLOC]]
// CHECK:       scf.if %[[ARG0]]
// CHECK:         %[[ALLOC_0:.*]] = memref.alloc
// CHECK:         %[[OWN_0:.*]] = deallocation.own %[[ALLOC_0]]
// CHECK:         memref.store %[[CST]], %[[ALLOC_0]][%[[C0]], %[[C1]], %[[C1]]]
// CHECK:         deallocation.retain() of(%[[OWN_0]])
// CHECK:       else
// CHECK:         memref.store %[[CST]], %[[ALLOC]][%[[C0]], %[[C1]], %[[C1]]]
// CHECK:       deallocation.retain() of(%[[OWN]])
// CHECK:       return

// CHECK:     @user(%[[ARG0_0:.*]]: i1)
// CHECK:       call @ite_no_yielded_buffers(%[[ARG0_0]])
// CHECK:       return

// -----

func.func @may_reuse(%pred: i1, %arg: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %0 = scf.if %pred -> (memref<1x2x3xf32>) {
    scf.yield %arg : memref<1x2x3xf32>
  } else {
    %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
    scf.yield %alloc : memref<1x2x3xf32>
  }
  return %0 : memref<1x2x3xf32>
}

func.func @user(%pred: i1, %arg: memref<1x2x3xf32>) -> memref<1x2x3xf32> {
  %may_escape_indirectly = memref.alloc() {alignment = 64 : i64} 
      : memref<1x2x3xf32>
  %0 = call @may_reuse(%pred, %may_escape_indirectly) : (i1, memref<1x2x3xf32>)
      -> memref<1x2x3xf32>
  return %0 : memref<1x2x3xf32>
}

// CHECK:        @may_reuse(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>) 
// CHECK:          %[[IF:.*]]:2 = scf.if %[[ARG0]] -> (memref<1x2x3xf32>, !deallocation.ownership)
// CHECK:            %[[RETAIN:.*]] = deallocation.retain(%[[ARG1]]) of() : (memref<1x2x3xf32>) -> !deallocation.ownership
// CHECK:            scf.yield %[[ARG1]], %[[RETAIN]] : memref<1x2x3xf32>, !deallocation.ownership
// CHECK:          else
// CHECK:            %[[ALLOC:.*]] = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
// CHECK:            %[[OWN:.*]] = deallocation.own %[[ALLOC]] : memref<1x2x3xf32>
// CHECK:            scf.yield %[[ALLOC]], %[[OWN]] : memref<1x2x3xf32>, !deallocation.ownership
// CHECK:          return %[[IF]]#0, %[[IF]]#1 : memref<1x2x3xf32>, !deallocation.ownership

// CHECK:        @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>) -> (memref<1x2x3xf32>, !deallocation.ownership)
// CHECK:          %[[ALLOC_0:.*]] = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
// CHECK:          %[[OWN_0:.*]] = deallocation.own %[[ALLOC_0]] : memref<1x2x3xf32>
// CHECK:          %[[OWNERSHIP:.*]]:2 = call @may_reuse(%[[ARG0_0]], %[[ALLOC_0]]) : (i1, memref<1x2x3xf32>) -> (memref<1x2x3xf32>, !deallocation.ownership)
// CHECK:          %[[RETAIN_0:.*]] = deallocation.retain(%[[OWNERSHIP]]#0) of(%[[OWN_0]], %[[OWNERSHIP]]#1) : (memref<1x2x3xf32>, !deallocation.ownership, !deallocation.ownership) -> !deallocation.ownership
// CHECK:          return %[[OWNERSHIP]]#0, %[[RETAIN_0]] : memref<1x2x3xf32>, !deallocation.ownership

// -----

func.func @insert_may_reuse_and_forward(%arg0: i1, %arg1: memref<1x2x3xf32>)
    -> (memref<1x2x3xf32>, memref<1x2x3xf32>) {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index
  %cst = arith.constant 7.000000e+00 : f32
  %0 = scf.if %arg0 -> (memref<1x2x3xf32>) {
    %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
    memref.copy %arg1, %alloc : memref<1x2x3xf32> to memref<1x2x3xf32>
    memref.store %cst, %alloc[%c0, %c1, %c1] : memref<1x2x3xf32>
    scf.yield %alloc : memref<1x2x3xf32>
  } else {
    %alloc = memref.alloc() {alignment = 64 : i64} : memref<1x2x3xf32>
    memref.store %cst, %alloc[%c0, %c1, %c1] : memref<1x2x3xf32>
    scf.yield %alloc : memref<1x2x3xf32>
  }
  return %0, %arg1 : memref<1x2x3xf32>, memref<1x2x3xf32>
}

func.func @user(%arg0: i1, %arg1: memref<1x2x3xf32>)
    -> (memref<1x2x3xf32>, memref<1x2x3xf32>) {
  %5:2 = call @insert_may_reuse_and_forward(%arg0, %arg1)
      : (i1, memref<1x2x3xf32>) -> (memref<1x2x3xf32>, memref<1x2x3xf32>)
  return %5#0, %5#1 : memref<1x2x3xf32>, memref<1x2x3xf32>
}

// CHECK:     @insert_may_reuse_and_forward(%[[ARG0:.*]]: i1, %[[ARG1:.*]]: memref<1x2x3xf32>)
// CHECK-DAG:   %[[C0:.*]] = arith.constant 0
// CHECK-DAG:   %[[C1:.*]] = arith.constant 1
// CHECK-DAG:   %[[CST:.*]] = arith.constant 7.0
// CHECK:       %[[IF:.*]]:2 = scf.if %[[ARG0]]
// CHECK:         %[[ALLOC:.*]] = memref.alloc
// CHECK:         %[[OWN:.*]] = deallocation.own %[[ALLOC]]
// CHECK:         memref.copy %[[ARG1]], %[[ALLOC]]
// CHECK:         memref.store %[[CST]], %[[ALLOC]][%[[C0]], %[[C1]], %[[C1]]]
// CHECK:         scf.yield %[[ALLOC]], %[[OWN]]
// CHECK:       else
// CHECK:         %[[ALLOC_0:.*]] = memref.alloc
// CHECK:         %[[OWN_0:.*]] = deallocation.own %[[ALLOC_0]]
// CHECK:         memref.store %[[CST]], %[[ALLOC_0]][%[[C0]], %[[C1]], %[[C1]]]
// CHECK:         scf.yield %[[ALLOC_0]], %[[OWN_0]]
// CHECK:       %[[RETAIN:.*]] = deallocation.retain(%[[ARG1]]) of()
// CHECK:       return %[[IF]]#0, %[[ARG1]], %[[IF]]#1, %[[RETAIN]]

// CHECK:     @user(%[[ARG0_0:.*]]: i1, %[[ARG1_0:.*]]: memref<1x2x3xf32>)
// CHECK:       %[[OWNERSHIP:.*]]:4 = call @insert_may_reuse_and_forward(%[[ARG0_0]], %[[ARG1_0]])
// CHECK:       %[[RETAIN_0:.*]]:2 = deallocation.retain(%[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1) of(%[[OWNERSHIP]]#2, %[[OWNERSHIP]]#3)
// CHECK:       return %[[OWNERSHIP]]#0, %[[OWNERSHIP]]#1, %[[RETAIN_0]]#0, %[[RETAIN_0]]#1
