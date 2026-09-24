// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice REAL redstone-primary-prod packages captured from the public gateway on 2026-09-24
///         (two snapshots 20s apart: A then B). Values in 8 decimals, one per signer,
///         signatures exactly as signed by RedStone's nodes — no mocked signatures.
library RedstoneFixtures {
	struct Snapshot {
		bytes32 feedId;
		uint64 timestampMs;
		uint256[] values;
		bytes[] signatures;
	}

	function signers() internal pure returns (address[] memory s) {
		s = new address[](5);
		s[0] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
		s[1] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
		s[2] = 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de;
		s[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
		s[4] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
	}

	function ethA() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('ETH');
		s.timestampMs = 1790276350000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 269176060100;
		s.signatures[0] = hex'4737e36a71b2a67e500517f1fa573860713bb6f70f85f5c529215b2f5805a487574ab1596034a297afc14c8fc35c4947de9c482f7b86192c9e4aed929c16c9321b';
		s.values[1] = 269175969913;
		s.signatures[1] = hex'496be3fe91cde4df0530ebd93be60c52c15c0a934b9c011a1e46c3232929861503bf427d6e0cf8e2a75d9d60ca87ef986a9893c0aec5c69a40c4b2623b94bf061b';
		s.values[2] = 269186976120;
		s.signatures[2] = hex'239a8b3ac835c77a47687f1c677b8b151a8131fdbc9f20d94d0e2b7e068d0ca57ebe5859693fe19ce91b7535741bc4665edfd25425755e13ae2d5e626683d5ed1c';
		s.values[3] = 269175969913;
		s.signatures[3] = hex'7accd01566be433b2ee84e8c813c0529a55929f1d5301de04b74123e876e791d139a33af048f51908f3a43f26860350681dda8064b9b10a069e44e5ddab2c9311b';
		s.values[4] = 269175969913;
		s.signatures[4] = hex'fe01a5b1c3f4dcc63638f96152907a699a869e3f43609ccbf8808d22dc7261bc4fdbfbf382d54eae6514289f07cb1f7d7568cdf168301476d15a804a2fc9439d1b';
	}

	function arbA() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('ARB');
		s.timestampMs = 1790276350000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 21927256;
		s.signatures[0] = hex'6aa501aa4df84db3c5576d8d51dfd49cc77e305af85c907ac392559faf2a688c2533063c8f6fb8b1032c2e53ad6da79333531c4ce119a0efe80bf0c3cd3c6d3c1c';
		s.values[1] = 21927256;
		s.signatures[1] = hex'c500be15c4572c21c7de24813afed09201d73e7389597b3aff5b209c27473ecb6897144d2d02f311f617ff9d9006911729fe94fc21c8cd528432ea8d113415d21b';
		s.values[2] = 21927257;
		s.signatures[2] = hex'33642ce08bcd995cd35522b1e36f67220317085698250770a34967204d24ddf546e0cdc289ba164a9456a277eec7be4433d677b37298ec990f7d518214845dac1c';
		s.values[3] = 21927256;
		s.signatures[3] = hex'52bd6c86aa8d49807b99e72e112659cb9d3d04111c46fb1a7585e5d1217b4c2c580a41ed9725a8fb9e8ff33d0965707cf69105aae8e4c639e9bd550f241484b91b';
		s.values[4] = 21927256;
		s.signatures[4] = hex'9824bd278207bc6b48a362e5203e4e72b65491f68c61e4c937cc8f0da625a76172e26eb81b3d7a5b77fb329a92d0654582a4f39833273cae29b1abece135eb3e1c';
	}

	function amdA() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('AMD');
		s.timestampMs = 1790276350000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 62853818680;
		s.signatures[0] = hex'a9255a895bbdee27a7038c946e6e800568776c2dfd660d537cca233e2c23b0000db6483dbfc83fd6aa65c77e3eccc4be0fa258ce1c49b504df2fac6d6697f0761c';
		s.values[1] = 62851295003;
		s.signatures[1] = hex'2d6526c4ffe88a37b9475c4e686feb36c23dcc805d83e7e0495acd164f01651f5c371e7a7d0a837faf98a53a2dc135073bc8b9c1e7e9c70c2bb4997f8102fbeb1c';
		s.values[2] = 62847643934;
		s.signatures[2] = hex'3d4384279f89417bd024ba18d61444d0f84d41bd677ae6511ee512f3cb08b01f3bb5ff33d5e9a1db8581ea2f277c7cc2a56637c3408290f13d56eb8953f489391c';
		s.values[3] = 62853436623;
		s.signatures[3] = hex'2a94b279003b2c6f95528fc6b668204ec2c4d89b56a61dcb95fc58e7196a85d56951975ee72a87b603357560a2e782363dadfe7c158c7007313bf2c361b90d5c1b';
		s.values[4] = 62847445041;
		s.signatures[4] = hex'6f0969b1f3578b6129d9389927e9ab2954f163529df1c7295c171bd4755230c030c9cd637f4eff2395bc060fcf18e2f72d785243fad08daefff2e3de64fc3d2a1b';
	}

	function ethB() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('ETH');
		s.timestampMs = 1790276370000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 269081403030;
		s.signatures[0] = hex'8bc8f137ec4ab134f73d14564cba8bb72aade3eb79bf5b280d68e8d36ba05a9522d351af697cd27e2b1c96669ba0e7acd9f8c7fc6ff1b5604fc7b0fb536edb0e1b';
		s.values[1] = 269082402660;
		s.signatures[1] = hex'055e21a789e967cc6794c21b893f2b80de1660c68be832d157eda3481fc09fb8285070ef442a4a5fad10fb6d76b45c073a4bb27303f522f9247517cd33a4ca1b1c';
		s.values[2] = 269082402660;
		s.signatures[2] = hex'b2ca4de554811fbd6c0ad9f1e70f6d6b99d9a7fb5ec26d7476b5fc5e4bff50ef5ea83e3491b6978a9a08afd195d305883186e6c7e0f9b98748513d5c120062201c';
		s.values[3] = 269082402660;
		s.signatures[3] = hex'af675949494027ac17948a7e39d5a874cace7b0bd86d48daf1a76934d69de641475cb3ffba466161c3b4dd51e62cab204bbbb54e1feb90761c2e7fe6f5584fd81c';
		s.values[4] = 269082402660;
		s.signatures[4] = hex'050b94a8d570ac25b078f5b4e0b378ca5565b4f6730cec53b6dae4856de7fe554a3c28476b83f08ef27c1c36bc6a848a63c41ceaba4225c624a70faad0f9c1db1c';
	}

	function arbB() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('ARB');
		s.timestampMs = 1790276370000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 21920000;
		s.signatures[0] = hex'139f92e8986c93b02fd5dd8ec0da00eb312c50ef289ed311d514359da34034580b113692d7c5edee5f38849328cdbdca2fa94b4b6ae906485609817e003dfc7a1c';
		s.values[1] = 21920000;
		s.signatures[1] = hex'fb38e46ebb8fdfca68c4ea30e8e9b06ca0adb831de887fd47de125bd15f694405dd755643b8799d38a0067dd27acc5a4ba60e859e33727884cda7c0001e599d11b';
		s.values[2] = 21920000;
		s.signatures[2] = hex'680cee9be0fb921a6f8689aea3effacaf243c5832e1c2510682ee4d82db1c36723ba0825e58e7e4b5bd75d846046456eba591e6ceae34cb858dda6bcac9dcc011c';
		s.values[3] = 21920000;
		s.signatures[3] = hex'6cb7559b1b20ac2bc8c3f02e7d245e8b8e035cfbefb5e4a9062d7a16234c869c54efc69f4435502f7ce49da5af1cc714aab96442f2e749f356f5137d49e4c3a91c';
		s.values[4] = 21920000;
		s.signatures[4] = hex'83aa8df85308ee5cc4c59d933cbb586e3a943355dc83fc04dc75853f706f0bf46d8d90235cbeabcd35214e793003fa4bb77e79142e731d4a7b905eeffbbc2e4b1c';
	}

	function amdB() internal pure returns (Snapshot memory s) {
		s.feedId = bytes32('AMD');
		s.timestampMs = 1790276370000;
		s.values = new uint256[](5);
		s.signatures = new bytes[](5);
		s.values[0] = 62883658483;
		s.signatures[0] = hex'22e3291a9546bd3df8be5ffe8f2d0f1b40a9d0d66cddc1f95f169e6a0b66daea2a683cd9bfcb87d412cfb8db1e0bdaeec6746ab3fccdc47682d52c7a9c10c40b1b';
		s.values[1] = 62881465404;
		s.signatures[1] = hex'50653d916a1a44f6794bf6356fd67b52b5494049dbaa5289887ea522042a31dd5626f3f703608eb0becf09488141faa42e6dc846472606ede7941b6b18c2e2901c';
		s.values[2] = 62882686052;
		s.signatures[2] = hex'de71894d2d7a3e12243b83399fa26d448db09989e907aabc61801ac21663eb710461c9044b1053468968880f1535ffdc43e8519f008511f945983656e17dfbd91c';
		s.values[3] = 62883573754;
		s.signatures[3] = hex'3f1d462737f080bbb898896a0ee21702a51f809b329ed0bf49c1e9eedd0487f96648ebca7904217a625ca829bc7acd3c61a1790a7aae9f4579386e5adb23ae021c';
		s.values[4] = 62883560328;
		s.signatures[4] = hex'e6698aa54c9b299ae545f445bc396cc344502feec23e1fa25539948740a53aed117e41e3301a76d8a04b749cc39e78715ac380980ae854b415913de2e4fddb071b';
	}

}
