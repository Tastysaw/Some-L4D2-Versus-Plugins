# Some  Plugins for Versus 一些用于对抗的额外插件（L4D2）
> 一些在各种服务器看到的小功能然后仿照自行编写(不定期更新)

* 你作为一名药抗腐竹可能经常在各种药抗服务器看到各种提升体验的小插件，但是苦于某些功能属于腐竹定制非公开插件，而你又很想要这个功能，其实我也是这么想的，所以我把一些自己编写的插件分享在此处。

> \[!IMPORTANT]
> 我不是专业编写插件的，纯热爱，我是做CS2地图的（已洋洋得意）。

   * 由于测试条件有限，无法保证插件一定不存在bug
   * 编译插件所需扩展与头文件基本来源于Zonemod插件包自带的，如果用到其他头文件会一并上传
   * 尽量上传编译好的smx文件，当然如果可以最好知道如何编译插件
   * 使用的Sourcemod的版本为1.12
  
  
> \[!TIP]
> 小提示

   * 基本只支持简体中文
   * 如果你选择使用这里的插件的话遇到bug最好能反馈一下最好

----

 * <details><summary><b>额外插件</b></summary>
  * [l4d2_horde_counter](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_horde_counter) : 尸潮开始与结束提示
    * 触发尸潮事件时提示开始与结束，还有一个升级版是屏幕上实时显示当前小僵尸数量，但是还未上传于此（参考自坦克训练服）

  * [l4d2_witch_jockey_skill](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_witch_jockey_skill) : witch击杀技巧检测与推停jockey检测

    * 对于Zonemod技巧检测的补充，witch的检测其实是Zonemod自带的那个没开罢了，制作这个插件的时候没注意，就这样吧

  * [l4d2_tank_si_stats](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_tank_si_stats) : 统计克局其他特感造成伤害量

    * 克局结束打印其他三人造成的伤害，谁在摸鱼！

  * [l4d2_round_control_stats](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_round_control_stats) : 统计生还被控次数

    * 回合结束打印生还被控及吃拳饼数，看看谁最会防控

  * [l4d2_rock_trail](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_rock_trail): 显示石头轨迹

    * 改编插件适配于药抗，可以在cfg里设置哪个阵营可见，默认特感+观察

  * [l4d2_join_location](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/l4d2_join_location): 加入与退出提示

    * 显示玩家加入的城市和退出的原因，仿照Love平台制作的玩家加入与退出
   
</details>

 * <details><summary><b>替换Zonemod插件</b></summary>
 
  * [readyup](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/readyup) : Zonemod readyup插件的中文增强版

    * 替换Zonemod原生readyup面板，带时长检测和双方得分

  * [spechud](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/spechud) : Zonemod 坦克面板及观战面板中文增强版

    * 带拳饼铁和总伤害显示

  * [pause](https://github.com/Tastysaw/Some-L4D2-Versus-Plugins/tree/main/pause) : Zonemod 暂停插件增强版

    * 增加了如果玩家闪退自动暂停这个玩家重连之后会自动解除暂停

</details>
  


