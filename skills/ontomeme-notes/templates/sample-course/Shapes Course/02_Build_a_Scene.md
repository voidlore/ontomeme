---
title: Lesson 2: Build a Scene
tags: course, shapes
---
In [[Lesson 1: Meet the Shapes]] you met the shapes. Now you'll place them yourself: one line per shape.

## One line, one shape
Write the shape, a colon, then a colour:

````text
```3d
cube: red
sphere: blue
```
````

```3d
cube: red
sphere: blue
caption: Two shapes
```

## Position and size
Add extras after commas: `at x z` moves a shape, `size` scales it, and `spin` turns it.

```3d
cube: red, at -2 0
sphere: blue, size 1.6
cone: yellow, at 2 0, spin
caption: Placed, sized and spinning
```

Try it: press Ctrl+1, change `size 1.6` to `size 3`, then press Ctrl+3.

## Flashcards

```3d
preset: flashcards
caption: Scene lines
objective: Build a scene from shapes
q: Which line makes a blue sphere?
a: sphere: blue
q: How do you make a shape bigger?
a: Add size and a number, like size 2
q: How do you make a shape turn?
a: Add spin
```

## Check yourself

```3d
preset: quiz
caption: Building scenes · 2 questions
objective: Build a scene from shapes
q: Which line shows a spinning blue cone?
a: blue: cone, spin
a*: cone: blue, spin
a: [[cone blue]]
why: Shape, colon, colour, then extras after commas.
learn: Lesson 2: Build a Scene
q: Which shape did Lesson 1 say has six square faces?
a*: Cube
a: Sphere
a: Cone
why: Six square faces make a cube.
learn: Lesson 1: Meet the Shapes
```

You finished! Back to [[Start Here: Shapes Course]].
