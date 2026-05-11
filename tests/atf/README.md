# ATF/Kyua

Target smoke test coverage:

- listener-state creation from IGMP control traffic,
- delivery to one interested port,
- zero delivery to one uninterested port,
- safe fallback after state teardown or expiry.

The long-term goal is to mirror the final upstream test structure closely enough that porting the test into the FreeBSD tree is straightforward.
