Lets say you have the following simple function
```
fn myFunc(): <Console> Unit {
	print("Hello, World!");
}
```
After metaprocessing this should process to something like:
```
fn myFunc(print: String -> Unit): Unit {
	print("Hello, World");
}
```
This example is fairly simple. myFunc gets rewritten as part of metaprocessing to include print as a parameter when as a user it is handled by the effect.

```
run {
	myFunc();
} handle Console {
	fn print() {
		// some def here
	}
}
```

## Control Processing
What about effects with ctl, what happens there?

```
effect Console {
	fn print(String): Unit
}

effect Ask {
	ctl Ask(): String
}
```

```
fn myFunc(): <Ask, Console> Unit {
	var x = ask();
	print(x);
}
```

```
run {
	print("before");
	myFunc();
	print("after");
} handle Ask {
	ctl Ask() {
		print("before resume");metaprocessing
		resume("Hello");
		print("after resume");
	}
}
```

This should print:
```
before
before resume
Hello
after
after resume
```
But what does it process to?

Lets talk about what ask() processes to first
```
fn ask(print: String -> Unit, resume: String -> Unit) {
	print("before resume");
	resume("Hello");
	print("after resume");
}
```
This fn is fairly simple, it simply needs to wire in the implicit functions the challenging part is the caller. This gets metaprocessed to something like
```
print("before");
myFunc(print) {
	print("after");
}
```
Where the after here is passed in as a closure. Note that there is no unwinding here. It does a transform during meta processing.