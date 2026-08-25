#!/usr/bin/env python3
"""生成 OpenCode-Go-Quotas dmg 的 .DS_Store(现代 Finder 规范格式)。

用法: make-dsstore.py <mount_point> <volume_name>
- 必须在「已挂载的可写镜像」上运行(镜像需先以 UDRW 构建并挂载),这样
  backgroundImageAlias 才能引用卷内真实文件(mac_alias.Alias)。
- 格式对齐 dmgbuild 的现代写法(dmgbuild PR #275):
  * 根条目 vSrn / bwsp(窗口状态)/ icvp(图标视图选项)/ icvl(视图类型)
  * icvp 用 backgroundType=2 + backgroundImageAlias,**不写 pBBk Bookmark**
    —— macOS Tahoe 26.2+ 对 pBBk 有回归 bug,写了背景就不显示;
  * 不用远古的 icvB/icvI 路径形式与 fwsw/fwsn。
依赖: pip3 install --user ds_store mac-alias(py3 兼容见下方 patch)
"""
import os
import struct
import sys

from ds_store import buddy
from ds_store.store import DSStore
from mac_alias import Alias


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
    mount = sys.argv[1]
    vol = sys.argv[2]
    app_name = 'OpenCode-Go-Quotas.app'

    bg = os.path.join(mount, '.background.png')
    alias = Alias.for_file(bg)

    ds_path = os.path.join(mount, '.DS_Store')
    open(ds_path, 'wb').close()  # 'w' 模式经 r+b 句柄写入,需先建文件
    ds = DSStore.open(ds_path, 'w')
    ds['.']['vSrn'] = ('long', 1)
    ds['.']['bwsp'] = {
        'ShowStatusBar': False,
        'WindowBounds': '{{0, 0}, {600, 400}}',
        'ContainerShowSidebar': False,
        'PreviewPaneVisibility': False,
        'SidebarWidth': 0,
        'ShowTabView': False,
        'ShowToolbar': True,
        'ShowPathbar': False,
        'ShowSidebar': False,
    }
    ds['.']['icvp'] = {
        'viewOptionsVersion': 1,
        'backgroundType': 2,
        'backgroundImageAlias': alias.to_bytes(),
        'gridOffsetX': 0.0,
        'gridOffsetY': 0.0,
        'gridSpacing': 60.0,
        'arrangeBy': 'none',
        'showIconPreview': True,
        'showItemInfo': False,
        'labelOnBottom': True,
        'textSize': 12.0,
        'iconSize': 64.0,
        'scrollPositionX': 0.0,
        'scrollPositionY': 0.0,
    }
    ds['.']['icvl'] = (b'type', 'icnv')
    ds[app_name]['Iloc'] = (150, 130)
    ds['Applications']['Iloc'] = (390, 130)
    ds.close()
    print('DS_Store written')


if __name__ == '__main__':
    main()
