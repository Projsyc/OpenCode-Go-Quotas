#!/usr/bin/env python3
"""生成 OpenCode-Go-Quotas dmg 的 .DS_Store(布局:背景图 + 图标位置,兼容 macOS Finder)。

用法: make-dsstore.py <staging_dir> <volume_name>
依赖: pip3 install --user ds_store(python2 时代的库,此处打补丁兼容 py3)
"""
import struct
import sys

from ds_store import buddy
from ds_store.store import DSStore


def patched_open(cls_factory_unused, file_or_name, mode='r+'):
    """修复 ds_store(0.4,py2 时代)在 py3 的两个问题:
    1. 'w' 模式用 'wb' 打开后不可读(库自身要读)
    2. 写头部后未 seek(0)(Allocator 从当前指针读)
    实现等价于库源码的 w 模式初始化,但用 r+b 句柄并在写入后归零指针。
    """
    if isinstance(file_or_name, str):
        if 'w' in mode:
            f = open(file_or_name, 'r+b')
        else:
            mode2 = mode if 'b' in mode else mode[:1] + 'b' + mode[1:]
            f = open(file_or_name, mode2)
    else:
        f = file_or_name
    if 'w' in mode:
        f.truncate()
        header = struct.pack(
            b'>I4sIII16s',
            1, b'Bud1', 2048, 1264, 2048,
            b'\x00\x00\x10\x0c\x00\x00\x00\x87\x00\x00\x20\x0b\x00\x00\x00\x00')
        f.write(header)
        f.write(b'\0' * 2016)
        free_list = [struct.pack(b'>5I', 0, 0, 0, 0, 0)]
        for n in range(5, 11):
            free_list.append(struct.pack(b'>II', 1, 2 ** n))
        free_list.append(struct.pack(b'>I', 0))
        for n in range(12, 31):
            free_list.append(struct.pack(b'>II', 1, 2 ** n))
        free_list.append(struct.pack(b'>I', 0))
        root = b''.join([
            struct.pack(b'>III', 1, 0, 2048 | 5),
            struct.pack(b'>I', 0) * 255,
            struct.pack(b'>I', 0),
        ] + free_list)
        f.write(root)
        f.seek(0)
    return buddy.Allocator(f)


buddy.Allocator.open = classmethod(patched_open)


def main():
    stage = sys.argv[1]
    vol = sys.argv[2]
    ds = DSStore.open(f'{stage}/.DS_Store', 'w')
    root = ds['.']
    root['icvp'] = {
        'icvh': 1, 'icvV': 1, 'icvS': 48, 'icvU': 0, 'icvG': 40, 'icvL': 0,
        'icvB': -1,
        'icvI': f'/Volumes/{vol}/.background/background.png',
    }
    root['fwsw'] = ('long', 600)
    root['fwsn'] = ('long', 400)
    ds['OpenCode-Go-Quotas.app']['Iloc'] = (150, 130)
    ds['Applications']['Iloc'] = (390, 130)
    ds.close()
    print('DS_Store written')


if __name__ == '__main__':
    main()
