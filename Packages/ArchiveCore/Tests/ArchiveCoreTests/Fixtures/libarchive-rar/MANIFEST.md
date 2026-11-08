# libarchive RAR test fixtures

Decoded with `uudecode` from libarchive 3.8.11's own test suite
(https://github.com/libarchive/libarchive/releases/download/v3.8.11/libarchive-3.8.11.tar.gz,
SHA-256 900fe9fc7237c2b04f090f3c3648de8fe597525771f5035016537ce2d667d12b),
path libarchive/test/<name>.uu. Written by WinRAR / rar (RAR 2.0–4.x and RAR 5.0) for libarchive's tests.
Licence: BSD-2-Clause, as libarchive (see Packages/ArchiveCore/Sources/CLibArchiveRAR/COPYING).
The expected contents and CRC-32 values the mailin tests assert are the ones libarchive's
test_read_format_rar.c / test_read_format_rar5.c assert for the same files.

Encrypted files (audit R6): libarchive's test_read_format_rar_encryption.c states the passwords and
contents of the `rar4_*` / `rar5_*` encrypted files — four files a.txt … d.txt, "This is from <name>"
(18 bytes); "password" for every file of the solid and encrypted-file-name archives; in the other two
a.txt and c.txt plain, b.txt under "password", d.txt under "password2". The three
`test_read_format_rar_encryption_{header,data,partially}.rar` files (foo.txt, bar.txt) carry no
published password in libarchive's tests; "12345678" (libarchive's 7z/ZIP encryption test password)
opens them and yields "data of foo.txt\n" / "data of bar.txt\n", which match the CRC-32 WinRAR
wrote into their headers (0xA6AD865C, 0xCD90E2BE).

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
| test_read_format_rar4_encrypted_filenames.rar | libarchive/test/test_read_format_rar4_encrypted_filenames.rar.uu | 460 | 0201a8cd86c15c117c7541d841c36c0dbabb4824396f19889db5f7d5364e7ef9 |
| test_read_format_rar4_solid_encrypted_filenames.rar | libarchive/test/test_read_format_rar4_solid_encrypted_filenames.rar.uu | 428 | 867341376d5b9a922ec3283c8111821b0435e4cbc493efde8b5083ae3b5ed340 |
| test_read_format_rar5_encrypted_filenames.rar | libarchive/test/test_read_format_rar5_encrypted_filenames.rar.uu | 718 | b2b98004c9cbf4f2a4000380ad47a16dea99f2d50835b1602c40d724eb82c300 |
| test_read_format_rar5_solid_encrypted.rar | libarchive/test/test_read_format_rar5_solid_encrypted.rar.uu | 475 | 307de6b76f6b7cc3a221975e14b8a6d7a6b87a30fd1ee7a0e08e4333724e5657 |
| test_read_format_rar5_solid_encrypted_filenames.rar | libarchive/test/test_read_format_rar5_solid_encrypted_filenames.rar.uu | 654 | 61bcc1272cc827fe607f0388d19f8d48c54af9b2cdb7bc0e32ebd2e369c0847e |
| test_read_format_rar_encryption_data.rar | libarchive/test/test_read_format_rar_encryption_data.rar.uu | 185 | 84ba9afcf0673aab0d1421d931e76a19294b12117483879c4b58598d3d71e83e |
| test_read_format_rar_encryption_partially.rar | libarchive/test/test_read_format_rar_encryption_partially.rar.uu | 173 | 144ab2270d4f28a61a857d5ae6248e90ab3be5ed46dc2fc59f9c0a98c7f49407 |
