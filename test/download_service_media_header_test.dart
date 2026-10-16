import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';

/// 媒体文件「头魔数校验」回归测试。
///
/// 背景：曾出现两类真实损坏——断点续传错位落盘导致文件只剩服务端中后段
/// （头部是音频中间，不是容器头）。这类文件用大小校验发现不了，
/// 只能靠头部校验拦截，所以本校验的准确性直接决定坏文件能否被拦住。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kikoflu_media_head_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 写入 [bytes] 到随机文件名，返回 File。
  Future<File> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(Uint8List.fromList(bytes));
    return f;
  }

  Future<bool> corrupt(String name, List<int> bytes) async {
    return DownloadService.isCorruptMediaFile(await write(name, bytes), name);
  }

  group('wav 头校验', () {
    test('RIFF/WAVE 开头判为正常', () async {
      expect(
        await corrupt('a.wav', [
          0x52, 0x49, 0x46, 0x46, // RIFF
          0x4E, 0xB4, 0xDA, 0x08,
          0x57, 0x41, 0x56, 0x45, // WAVE
        ]),
        isFalse,
      );
    });

    test('「只剩尾段」的真实坏文件（头部是低电平 PCM）判为损坏', () async {
      // 实测样本 289670/本編/#6.きりへの告白.wav 的开头 12 字节
      expect(
        await corrupt('bad.wav', [
          0xE8, 0x01, 0x00, 0xCE, 0xFC, 0xFF,
          0xEC, 0x00, 0x00, 0x40, 0xFC, 0xFF,
        ]),
        isTrue,
      );
    });
  });

  group('mp3 头校验', () {
    test('合法帧头（MPEG1 Layer3 / 128kbps / 44.1kHz）判为正常', () async {
      expect(
        await corrupt('ok.mp3', [0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00]),
        isFalse,
      );
    });

    test('ID3 标签开头判为正常', () async {
      expect(
        await corrupt('tagged.mp3', [
          0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00,
        ]),
        isFalse,
      );
    });

    test('「被切在帧中间」的真实坏文件（8c 17 0b 86…）判为损坏', () async {
      // 实测样本 271938/本編/mp3/本編/①頭なでなで.mp3 的开头 12 字节。
      // 旧实现只比对 2 字节同步字即可正确拒绝，此处用于防止回归。
      expect(
        await corrupt('bad.mp3', [
          0x8C, 0x17, 0x0B, 0x86, 0xCB, 0xD5,
          0x5B, 0x04, 0xAD, 0xC3, 0x63, 0x12,
        ]),
        isTrue,
      );
    });

    test('同步字偶合但字段非法的字节序列必须判为损坏', () async {
      // 0xFF 0xFB 命中同步字，但 byte2 = 0xF0 → 码率索引 15（非法保留值）。
      // 旧实现（只看前 2 字节）会误判为「正常」，从而放行错位落盘的数据。
      expect(
        await corrupt('fake.mp3', [0xFF, 0xFB, 0xF0, 0x00, 0x00, 0x00]),
        isTrue,
      );
    });

    test('采样率索引为保留值(3)判为损坏', () async {
      // byte2 = 0x9C → 码率索引 9（合法），采样率索引 (0x9C>>2)&3 = 3（保留值）
      expect(
        await corrupt('fake2.mp3', [0xFF, 0xFB, 0x9C, 0x00, 0x00, 0x00]),
        isTrue,
      );
    });

    test('不足 3 字节无法构成帧头，判为损坏', () async {
      expect(await corrupt('tiny.mp3', [0xFF, 0xFB]), isTrue);
    });
  });

  group('边界', () {
    test('非媒体扩展名不做校验', () async {
      expect(await corrupt('a.txt', [0x8C, 0x17, 0x0B, 0x86]), isFalse);
      expect(await corrupt('a.lrc', [0x8C, 0x17, 0x0B, 0x86]), isFalse);
    });

    test('比魔数还短的文件判为损坏', () async {
      expect(await corrupt('short.wav', [0x52, 0x49]), isTrue);
    });

    test('文件不存在时不判为损坏（读取失败按正常处理）', () async {
      final missing = File('${tmp.path}/not_exists.wav');
      expect(await DownloadService.isCorruptMediaFile(missing, 'not_exists.wav'),
          isFalse);
    });
  });
}
