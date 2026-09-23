# Flat types
In cronyx you might have 2 different types:
```
type Point {
	x: int,
	y: int
}

flat type FlatPoint {
	x: int,
	y: int
}

var p = Point { x: 3, y: 4 };
var fp = FlatPoint { x: 3, y: 4 };
```

These 2 variables look VERY similar, but they function very differently. Here p is a reference to the heap allocated Point. Where fp is the stack allocated 8 bytes representing a FlatPoint.

It is a bit clearer when you have recursive types:
```
type Rect1 {
	p1: Point, // bytes represent reference 
	p2: Point,
}

type Rect2 {
	p1: FlatPoint, // bytes represent data
	p2: FlatPoint,
}
```
Note it doesn't matter if these Rects are flat or not, the flatness corresponds to byte layout.
## Reassignment
Lets say you take the above definitions and do something like:
```
var p1 = Point { x: 3, y: 4 };
var fp1 = FlatPoint { x: 3, y: 4 };

var p2 = p1;
var fp2 = fp1;
```
What actually happens here?

Well p2 is still a reference to p1 so it just copies the reference from p1 to p2. Life continues as normal.

I think for fp2 = fp1 it should also just copy over the data. Lets not do weird rust moves yet, just copy the data (shallow not deep).

But lets look at what happens if you mutate these variables:
```
var p1 = Point { x: 3, y: 4 };
var fp1 = FlatPoint { x: 3, y: 4 };

var p2 = p1;// (5, 6)
var fp2 = fp1;

p2.x = 5;
p2.y = 6;
fp2.x = 5;
fp2.y = 6;
 
print(p1); // (5, 6)
print(p2); // (5, 6)
print(fp1); // (3, 4)
print(fp2); // (5, 6)
```
Because p1's reference was copied, p2's mutation affected the same underlying object. For fp1 and fp2, the actual data was copied instead so mutation did not affect the original object.
## Primitives
Primitives in cronyx really just represent flat types. They are not references, they are just data. int, bool, float are all just encodings for bytes.
## Referencing a Flat Type
```
fn scaleFlat(fp: FlatPoint, scalar: int) {
	fp.x *= scalar;
	fp.y *= scalar; 
}

fn scaleRef(fpRef: &FlatPoint, scalar: int) {
	(*fpRef).x *= scalar;
	(*fpRef).y *= scalar; 
}

var fp = FlatPoint { x: 3, y: 4 };
print(fp); // (3,4)
scaleFlat(fp, 2);
print(fp); // (3,4)
scaleRef(&fp, 2);
print(fp); // (6,8)
```
Here we can show pass-by-value in action. We know that in scaleFlat we pass by value meaning we copy the data into the param, so modifying the data "swallows" the output similiarly to in the assignment mutation case.
However when we pass the fp as reference, we do not have the corresponding issue since we pass the value of the reference meaning we are pointing to the appropriate location in memory.
## Boxing a Flat Type
A useful concept for flat types is the concept of a Box. A box is a structure that allows you to heap allocate flat types. 
```
var boxedFp = Box(FlatPoint {x: 3, y: 4}); // data is stored on the heap not the stack
```

## Recursive Typing
Boxes can be very useful when defining a recursive type. The following type is an error:
```
flat type LinkedList<T> { // size depends on size of cons
	Cons(T, LinkedList<T>), // size depends on size of LinkedList<T>
	Nil
}
```
This is because ALL type sizes must be known at compile time. This type's size is recursive because it may contain a reference to itself. 

This specific example can be solved by boxing the next element instead of referencing it explicitly.

```
flat type LinkedList<T> {
	Cons(T, Box<LinkedList<T>>), // Box has known size
	Nil
}
```
This types size is well defined because the size of Box is well defined. The data of the next element is heap allocated so the size is a pointer, not some arbitrarily large data structure.

NOTE: this specific code looks suspiciously similar to:
```
type LinkedList<T> {
	Cons(T, LinkedList<T>),
	Nil
}
```

Are these 2 actually the same? They are extremely similar in a lot of ways? Does regular typing just auto box flat types at construction??

# Static and Dynamic Dispatch
Lets say you have the following types
```
trait Speaker {
	fn speak(&self);
}

type Dog;
impl Speaker for Dog {
	fn speak(&self) {
		print("Woof");
	}
}

type Cat;
impl Speaker for Cat {
	fn speak(&self) {
		print("Meow");
	}
}
```

You can invoke both of these statically with:
```
makeSpeak<T: Speaker>(speaker: T) {
	speaker.speak()
}

var dog = Dog;
var cat = Cat;

makeSpeak(dog); // Woof
makeSpeak(cat); // Meow
```
This is because of monomorphism, a different implementation of this method is created for each type that implements Speaker (which calls this method).

Invoking methods statically is very powerful. However, you do lose some ergonomics when you do static dispatch. For instance what if you wanted to make a list of pets and call speak on each of them. You cannot do that with this pattern since Cat and Dog are different types.

## Dynamic Dispatch
```
makeSpeak(speaker: Speaker) {
	speaker.speak()
}

var dog = Dog;
var cat = Cat;

makeSpeak(dog); // Woof
makeSpeak(cat); // Meow
```
Note: In this example Speaker is used directly as the type instead of implementing the type. This means we are passing the data as a dynamic reference with a data pointer, and a vtable.

This specific example works the same but is actually technically slower than static dispatch and the compiler can do less inlining. However now you can do ergonomics like:

```
var speakers: List<Speaker> = [
	Cat,
	Dog,
]

for (var speaker in speakers) {
	makeSpeak(speaker);
}
```