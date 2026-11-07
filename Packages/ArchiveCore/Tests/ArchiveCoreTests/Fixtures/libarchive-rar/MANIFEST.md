# libarchive RAR test fixtures

Decoded with `uudecode` from libarchive 3.8.11's own test suite
(https://github.com/libarchive/libarchive/releases/download/v3.8.11/libarchive-3.8.11.tar.gz,
SHA-256 900fe9fc7237c2b04f090f3c3648de8fe597525771f5035016537ce2d667d12b),
path libarchive/test/<name>.uu. Written by WinRAR / rar (RAR 2.0–4.x and RAR 5.0) for libarchive's tests.
Licence: BSD-2-Clause, as libarchive (see Packages/ArchiveCore/Sources/CLibArchiveRAR/COPYING).
The expected contents and CRC-32 values the mailin tests assert are the ones libarchive's
test_read_format_rar.c / test_read_format_rar5.c assert for the same files.

| file | source | bytes | SHA-256 |
|---|---|---|---|
| test_read_format_rar.rar | libarchive/test/test_read_format_rar.rar.uu | 336 | d421b86f6290aefad61b2a36737253b2b30fe27c156bd95abfc230f24fe0307e |
| test_read_format_rar_compress_normal.rar | libarchive/test/test_read_format_rar_compress_normal.rar.uu | 14617 | 7d32e2ef511d0ade372345440838165df828197eff4d7816880dafde690cce03 |
| test_read_format_rar_compress_best.rar | libarchive/test/test_read_format_rar_compress_best.rar.uu | 12186 | 7005b3c6e169ae559f0183c5f0640fdd201b329cf61838c1ca45725949fe0e06 |
| test_read_format_rar_filter.rar | libarchive/test/test_read_format_rar_filter.rar.uu | 94301 | b058412adcd3329a868cb66561a224eb0acf22ad2d380ef5d9e17e432a47d6a8 |
| test_read_format_rar_ppmd_lzss_conversion.rar | libarchive/test/test_read_format_rar_ppmd_lzss_conversion.rar.uu | 176700 | 1c75b4b35d0f381b46918b4ff26b6579cbfc18b8e3c78d39ce3b5a97af606183 |
| test_read_format_rar3_lowdist_reset.rar | libarchive/test/test_read_format_rar3_lowdist_reset.rar.uu | 566 | 45ca17d52b91a6f24c48fe5d79b04cb26052f7e1d732d8bf8e459c433540f916 |
| test_read_format_rar4_encrypted.rar | libarchive/test/test_read_format_rar4_encrypted.rar.uu | 311 | c30dc6d10e59aaab1c863afa469d188c644a22d67d6e50ac7ca887e520f5fc8b |
| test_read_format_rar4_solid_encrypted.rar | libarchive/test/test_read_format_rar4_solid_encrypted.rar.uu | 323 | 428d44a21042069bbc1891c30a66c48f55540aa37dd8b7ff92c39c5914e3a4a6 |
| test_read_format_rar_encryption_header.rar | libarchive/test/test_read_format_rar_encryption_header.rar.uu | 220 | 67fa99d6f1d07d6dce56da85d22cd6271c16fbc7aad5efc6046b30425cc799b0 |
| test_read_format_rar_invalid1.rar | libarchive/test/test_read_format_rar_invalid1.rar.uu | 63 | f4de1dd1618c48ca91c8a0f0b0353cba7a26fd7182153de54ba83a8c7007e6fe |
| test_read_format_rar_multivolume.part0001.rar | libarchive/test/test_read_format_rar_multivolume.part0001.rar.uu | 60000 | 6c4d7f55cbf0a44aa0cafb283b0fd954ef625c9afc2fbe1cce4f201fc2508c63 |
| test_read_format_rar_multivolume.part0002.rar | libarchive/test/test_read_format_rar_multivolume.part0002.rar.uu | 60000 | d1c3d9558671095c2876a958201fbcc6f5722f866ef9e2cf87d9913de82b31e1 |
| test_read_format_rar_multivolume.part0003.rar | libarchive/test/test_read_format_rar_multivolume.part0003.rar.uu | 60000 | 98872418a02ad45e09c93b08d8418981fa33c77bdbefcdd1f033de9371c5f96e |
| test_read_format_rar_multivolume.part0004.rar | libarchive/test/test_read_format_rar_multivolume.part0004.rar.uu | 9201 | 229fb3c528593895f63c220843a0c4d2b88170407adc28f12b988e8f27695801 |
| test_read_format_rar5_stored.rar | libarchive/test/test_read_format_rar5_stored.rar.uu | 109 | 35d75e315d164d2e329afc28f7d844f013271b4fcffd4ddd78efcdd114a383a7 |
| test_read_format_rar5_compressed.rar | libarchive/test/test_read_format_rar5_compressed.rar.uu | 436 | 68f9d7e2662cd5bc5607ba9c6bf1edbf121cf3b08011a7d8643091791750a7c8 |
| test_read_format_rar5_multiple_files.rar | libarchive/test/test_read_format_rar5_multiple_files.rar.uu | 1656 | 65305723965a55a89b7e120d54807c6ae30b69532712aa20d3934296799e923b |
| test_read_format_rar5_multiple_files_solid.rar | libarchive/test/test_read_format_rar5_multiple_files_solid.rar.uu | 677 | 0aa2c652c06304dedd93019663c1d52d5e85055d5fdb8045bfcc4345b90b4a0f |
| test_read_format_rar5_solid.rar | libarchive/test/test_read_format_rar5_solid.rar.uu | 1050 | 1149dda288494ab6c954d0e3f2a8831318aaf9c69e7da741729bb0c681f924b5 |
| test_read_format_rar5_blake2.rar | libarchive/test/test_read_format_rar5_blake2.rar.uu | 642 | e2889c7498cb8065b9fd2338b142a135b906576a30d24acaf44850cca6fb845a |
| test_read_format_rar5_arm.rar | libarchive/test/test_read_format_rar5_arm.rar.uu | 41082 | c5b149097c4f3e17239d80d6c9897c1a5aa98608d4f2e74e711bea5ef8ca85dd |
| test_read_format_rar5_encrypted.rar | libarchive/test/test_read_format_rar5_encrypted.rar.uu | 391 | 72b69a1d5f5757511e683a9207166c60e91ce0846ae446b8b332b085f9e0ba48 |
| test_read_format_rar5_bad_tables.rar | libarchive/test/test_read_format_rar5_bad_tables.rar.uu | 185 | a5368fced1d7e0740221699bac2ec2c7f53f6a0f87d6d6eec93ff7b5bb296554 |
| test_read_format_rar5_truncated_huff.rar | libarchive/test/test_read_format_rar5_truncated_huff.rar.uu | 160 | e0b828fb606b4b3844423e8c346e1f77f77bf271dc8794346900c7370d700291 |
| test_read_format_rar5_multiarchive_solid.part01.rar | libarchive/test/test_read_format_rar5_multiarchive_solid.part01.rar.uu | 13312 | 6607f575dad0b28aaeb02298b4c04a0e5a606e77f952127d2d9e346f60616a26 |
| test_read_format_rar5_multiarchive_solid.part02.rar | libarchive/test/test_read_format_rar5_multiarchive_solid.part02.rar.uu | 13312 | eb119ed53511905ca6f1844c164b6246d8fcdca0d1f38a8e3fb13da9c0932fbd |
| test_read_format_rar5_multiarchive_solid.part03.rar | libarchive/test/test_read_format_rar5_multiarchive_solid.part03.rar.uu | 13312 | e814c3dbdaf3f613fd25c840065d25543f31e6b6c95505e7e25f47867a4812bd |
| test_read_format_rar5_multiarchive_solid.part04.rar | libarchive/test/test_read_format_rar5_multiarchive_solid.part04.rar.uu | 3280 | 9ff5a4e633b0e82a2ce6e022f3d389654dbb77a0906a34f107676d6673989c9f |
