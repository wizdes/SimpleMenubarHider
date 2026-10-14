"""Regression test for the `visible` magenta color-space bug.

The screenshot PNG is tagged with the display ICC profile, so reading its
pixels through an sRGB bitmap context converts magenta far from (255,0,255)
and `visible` reports HIDDEN. The fix draws with the image's own color space,
falling back to device RGB when it is NULL or not RGB.
"""
import pathlib
import re
import unittest

SOURCE = pathlib.Path(__file__).resolve().parent.parent / "smh-spike.m"


def read_source():
    return SOURCE.read_text()


class VisibleColorSpaceTest(unittest.TestCase):
    def test_uses_image_color_space(self):
        """Bitmap context must use the image's own color space."""
        src = read_source()
        self.assertIn(
            "CGImageGetColorSpace(image)",
            src,
            "visible must create the bitmap with CGImageGetColorSpace(image)",
        )

    def test_falls_back_to_device_rgb(self):
        """NULL or non-RGB image space must fall back to device RGB."""
        src = read_source()
        self.assertIn(
            "CGColorSpaceCreateDeviceRGB()",
            src,
            "visible must fall back to CGColorSpaceCreateDeviceRGB()",
        )
        self.assertIn(
            "kCGColorSpaceModelRGB",
            src,
            "visible must check for a non-RGB color space model",
        )
        self.assertIn(
            "CGColorSpaceGetModel",
            src,
            "visible must check CGColorSpaceGetModel before falling back",
        )

    def test_does_not_convert_through_srgb(self):
        """The sRGB conversion that moved magenta must be gone."""
        src = read_source()
        self.assertNotIn(
            "kCGColorSpaceSRGB",
            src,
            "visible must not create an sRGB color space for the bitmap",
        )
        self.assertNotIn(
            "CGColorSpaceCreateWithName",
            src,
            "visible must not convert through a named color space",
        )

    def test_does_not_release_borrowed_space(self):
        """Only a created fallback space may be released."""
        src = read_source()
        # The borrowed image space must not be released unconditionally.
        unconditional = re.findall(
            r"(?m)^\s*CGColorSpaceRelease\(colorSpace\);\s*$", src
        )
        self.assertEqual(
            unconditional,
            [],
            "must not unconditionally release the (possibly borrowed) colorSpace",
        )
        # There must still be a release for the owned fallback.
        self.assertIn(
            "CGColorSpaceRelease",
            src,
            "owned fallback color space must still be released",
        )


if __name__ == "__main__":
    unittest.main()
