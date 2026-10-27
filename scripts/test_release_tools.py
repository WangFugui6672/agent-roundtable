from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import select_simulator  # noqa: E402


def runtime(*names: str) -> dict[str, list[dict[str, object]]]:
    devices = [
        {
            "name": name,
            "udid": f"udid-{index}",
            "isAvailable": True,
        }
        for index, name in enumerate(names)
    ]
    return {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": devices}


class SelectSimulatorTests(unittest.TestCase):
    def test_prefers_a_base_iphone_over_special_editions(self) -> None:
        devices = runtime("iPhone Air", "iPhone 17 Pro Max", "iPhone 17")

        self.assertEqual(select_simulator.select_device(devices), "udid-2")

    def test_prefers_the_standard_model_over_an_economy_variant(self) -> None:
        devices = runtime("iPhone 17e", "iPhone 17")

        self.assertEqual(select_simulator.select_device(devices), "udid-1")

    def test_prefers_a_regular_pro_when_no_base_model_is_available(self) -> None:
        devices = runtime("iPhone 18 Pro Max", "iPhone 18 Pro", "iPhone Air")

        self.assertEqual(select_simulator.select_device(devices), "udid-1")

    def test_honours_an_explicit_device_name(self) -> None:
        devices = runtime("iPhone 17", "iPhone 18 Pro")

        self.assertEqual(
            select_simulator.select_device(devices, requested_name="iPhone 18 Pro"),
            "udid-1",
        )


if __name__ == "__main__":
    unittest.main()
