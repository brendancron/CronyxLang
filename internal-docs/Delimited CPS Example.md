# Delimited CPS example

## Before

```cronyx
effect Ask { ctl ask(): int; }

print("before");
var base = 10;
run {
    var n = ask();
    print(base + n);
} handle Ask {
    ctl ask() {
        print("asked");
        resume 5;
        print("resumed");
    }
}
print("after");
```

## After

```cronyx
print("before");
var base = 10;

var ev_ask = (k: (int) -> <Console> unit) => {
    print("asked");
    k(5);                      // resume 5: runs the body to the end of the block, then returns here
    print("resumed");
};

ev_ask((n: int) => {           // the body, split at ask(); ends at the end of the block
    print(base + n);
});

print("after");                // just the next statement
```

# Proposed

```cronyx
fn ask<Ctl>() {
    print("asked");
    resume(5); // must get this from Ctl
    print("resumed");
}

print("before");
var base = 10;

~some run equivalent with handle above ask~ {
    var n = ask();
    print(base + n);
}

print("after");
```

Processes to

```
fn ask(resume: Int -> Unit) {
	print("asked");
	resume(5);
	print("resumed");
}

print("before");
var base = 10;

ask() { n ->
	print(base + n);
}

print("after");
```

## Foreach
```
fn for_each(xs: Array<int>, f: (int) -> unit): unit {
    for (x in xs) { f(x); }
}


```