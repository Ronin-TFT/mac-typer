package main

import (
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
)

func main() {
	img := image.NewRGBA(image.Rect(0, 0, 1024, 1024))
	fill(img, img.Bounds(), color.RGBA{32, 36, 43, 255})
	roundRect(img, image.Rect(154, 280, 870, 744), 76, color.RGBA{247, 242, 232, 255})

	key := color.RGBA{47, 111, 115, 255}
	hot := color.RGBA{208, 90, 59, 255}
	for _, r := range []image.Rectangle{
		image.Rect(214, 352, 306, 426), image.Rect(334, 352, 426, 426), image.Rect(454, 352, 546, 426),
		image.Rect(574, 352, 666, 426), image.Rect(694, 352, 786, 426), image.Rect(370, 468, 462, 542),
		image.Rect(490, 468, 582, 542), image.Rect(610, 468, 774, 542),
	} {
		roundRect(img, r, 18, key)
	}
	roundRect(img, image.Rect(250, 468, 342, 542), 18, hot)
	roundRect(img, image.Rect(286, 584, 738, 660), 20, color.RGBA{32, 36, 43, 255})

	f, err := os.Create("build/icon.png")
	if err != nil {
		panic(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		panic(err)
	}
}

func fill(img draw.Image, r image.Rectangle, c color.Color) {
	draw.Draw(img, r, &image.Uniform{c}, image.Point{}, draw.Src)
}

func roundRect(img draw.Image, r image.Rectangle, radius int, c color.Color) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			if insideRoundRect(x, y, r, radius) {
				img.Set(x, y, c)
			}
		}
	}
}

func insideRoundRect(x, y int, r image.Rectangle, radius int) bool {
	cx := clamp(x, r.Min.X+radius, r.Max.X-radius-1)
	cy := clamp(y, r.Min.Y+radius, r.Max.Y-radius-1)
	dx, dy := x-cx, y-cy
	return dx*dx+dy*dy <= radius*radius
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
