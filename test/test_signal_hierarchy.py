"""Signal lookup checks for unittest and targeted cocotb simulation."""

import unittest
from types import SimpleNamespace

import cocotb
from cocotb.triggers import FallingEdge

from test_smoke import (
    TEST, TEST_CYCLES, _dout_signal, _readback_address, pattern, set_mode, setup,
)


def signal(value):
    return SimpleNamespace(value=value)


class ReadbackAddressTests(unittest.TestCase):
    def test_invalid_read_does_not_require_an_address(self):
        project = SimpleNamespace(rd_valid=signal(0))
        self.assertIsNone(_readback_address(project))

    def test_rtl_vector_address(self):
        for address in (0, 7, 100, 255):
            with self.subTest(address=address):
                project = SimpleNamespace(
                    rd_valid=signal(1), rd_addr=signal(address)
                )
                self.assertEqual(_readback_address(project), address)

    def test_gate_level_bit_blasted_address(self):
        for address in range(256):
            project = SimpleNamespace(rd_valid=signal(1))
            for bit in range(8):
                setattr(project, f"rd_addr[{bit}]", signal((address >> bit) & 1))
            self.assertEqual(_readback_address(project), address)

    def test_missing_address_bit_is_not_silently_ignored(self):
        project = SimpleNamespace(rd_valid=signal(1))
        with self.assertRaises(AttributeError):
            _readback_address(project)


class ReadDataHierarchyTests(unittest.TestCase):
    def test_rtl_read_data_under_user_project(self):
        data = signal(0x12345678)
        tb = SimpleNamespace(user_project=SimpleNamespace(dout=data))
        self.assertIs(_dout_signal(tb.user_project), data)

    def test_gate_level_macro_port_under_user_project(self):
        data = signal(0x12345678)
        tb = SimpleNamespace(
            user_project=SimpleNamespace(sram0=SimpleNamespace(A_DOUT=data))
        )
        self.assertIs(_dout_signal(tb.user_project), data)

    def test_rtl_read_data_is_preferred_over_macro_port(self):
        data = signal(0x12345678)
        project = SimpleNamespace(
            dout=data, sram0=SimpleNamespace(A_DOUT=signal(0x87654321))
        )
        self.assertIs(_dout_signal(project), data)

    def test_missing_read_data_raises_immediately(self):
        with self.assertRaisesRegex(AttributeError, "Could not find SRAM read-data"):
            _dout_signal(SimpleNamespace())


@cocotb.test()
async def hierarchy_matches_readback(dut):
    """Resolve the actual pending read throughout both self-test passes."""
    await setup(dut)
    project = dut.user_project
    dout = _dout_signal(project)
    self_test_addresses = []
    assert _readback_address(project) is None
    await set_mode(dut, TEST)
    for _ in range(TEST_CYCLES):
        await FallingEdge(dut.clk)
        address = _readback_address(project)
        if address is None:
            continue
        inverted_pass = len(self_test_addresses) < 256
        assert int(dout.value) == pattern(address, inverted_pass)
        self_test_addresses.append(address)
    assert self_test_addresses == list(range(256)) * 2


if __name__ == "__main__":
    unittest.main()
