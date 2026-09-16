// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'M1 控制器';

  @override
  String get startupFailedTitle => '应用启动失败';

  @override
  String get startupFailedBody => '这是应用自身的问题，与相机无关。下面这段文字说明了出错的地方，值得反馈。';

  @override
  String get startupUnknownError => '未知错误';

  @override
  String get continueToApp => '仍然进入应用';

  @override
  String get disconnectTitle => '断开连接？';

  @override
  String get disconnectBody =>
      '断开后会停止取景并关闭相机的 Wi-Fi —— 没人用它的时候，这正是相机希望的。配对信息会保留，下次连接不必再在相机上确认一次。';

  @override
  String get cancel => '取消';

  @override
  String get disconnect => '断开';

  @override
  String get dismiss => '知道了';

  @override
  String get guideTooltip => '首次使用与配对指引';

  @override
  String get disconnectTooltip => '断开与相机的连接';

  @override
  String get checkCameraTooltip => '检查相机是否还在';

  @override
  String get licencesTooltip => '开源许可、致谢与作者说明';

  @override
  String get licencesLegalese =>
      '本应用是针对 YI M1（C59Y1）相机的非官方第三方应用，与 YI Technology 无隶属、授权或背书关系。应用本身以 Apache-2.0 许可发布；此处随附的开源组件各自适用其自己的许可，名单见下。';

  @override
  String get cameraResponding => '相机有应答。';

  @override
  String get cameraSilent => '相机没有应答。';

  @override
  String get navCapture => '拍摄';

  @override
  String get navSync => '同步';

  @override
  String get firmwareNotConnected => '未连接';

  @override
  String albumListingRejected(String detail) {
    return '相机拒绝了列表参数，说明协议对不上：\n$detail';
  }

  @override
  String albumUnreachable(String detail) {
    return '连不上相机。\n$detail';
  }

  @override
  String albumOnThisPhone(String name) {
    return '已在本机（$name）';
  }

  @override
  String get albumNotOnPhone => '尚未同步到本机';

  @override
  String get actionShare => '分享';

  @override
  String get actionShareSubtitleOnPhone => '发送到其他应用';

  @override
  String get actionShareSubtitleNotOnPhone => '需要先同步';

  @override
  String get actionOpen => '打开';

  @override
  String get actionOpenSubtitleOnPhone => '用手机自带的看图应用';

  @override
  String get actionSyncThis => '同步这张';

  @override
  String get actionRemoveFromPhone => '从本机删除';

  @override
  String get actionRemoveFromPhoneSubtitle => '相机上的文件保留';

  @override
  String get actionDeleteFromCamera => '从相机删除';

  @override
  String get actionDeleteFromCameraSubtitle => '无法撤销；相机没有回收站';

  @override
  String albumShareSheetTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '分享 $count 张照片',
    );
    return '$_temp0';
  }

  @override
  String get albumRemoveConfirmTitle => '从本机删除？';

  @override
  String albumRemoveConfirmBody(String path) {
    return '相册里的这份副本会被删除，相机存储卡上的照片仍在 —— 这和“从相机删除”正好相反。\n\n$path';
  }

  @override
  String get remove => '删除副本';

  @override
  String get albumDeleteStarting => '准备中';

  @override
  String albumSelectedCount(int count) {
    return '已选 $count 张';
  }

  @override
  String albumTitleCount(int count) {
    return '相册  ·  共 $count 张';
  }

  @override
  String get albumSyncSelectedTooltip => '同步选中的照片';

  @override
  String get albumDeleteSelectedTooltip => '从相机删除选中的照片';

  @override
  String get albumDeleteBusyTooltip => '已有删除任务在进行';

  @override
  String get albumSelectTooltip => '选择照片';

  @override
  String get albumReloadTooltip => '从第一页重新读取全部';

  @override
  String albumSyncCount(int count) {
    return '同步 $count 张';
  }

  @override
  String albumShareCount(int count) {
    return '分享 $count 张';
  }

  @override
  String albumDeleteCount(int count) {
    return '删除 $count 张';
  }

  @override
  String get albumNotConnectedTitle => '未连接';

  @override
  String get albumNotConnectedBody => '相册是通过相机自己的 Wi-Fi 提供的，请先连接相机。';

  @override
  String get albumReadFailedTitle => '读不到存储卡';

  @override
  String albumReadFailedBody(String error) {
    return '$error\n\n相机的传输链路很慢，再试一次通常就好了。';
  }

  @override
  String get albumRetryListing => '重新读取列表';

  @override
  String get albumEmptyTitle => '没有找到照片';

  @override
  String get albumEmptyBody => '存储卡报告为空。如果相机里确实有照片，可能是链路繁忙导致列表被提前截断。';

  @override
  String get albumLookAgain => '再找一次';

  @override
  String get albumPreviewPending => '已保存预览图，原图尚未同步。';

  @override
  String get albumPathTooLong => '这个路径超出了固件拷贝用的 50 字节缓冲，无法获取。';

  @override
  String get albumNotConnectedShort => '尚未连接相机';

  @override
  String albumLoadFailed(String error) {
    return '从相机读取失败：$error';
  }

  @override
  String get albumSavedCopyGone => '这条记录显示已保存，但本机上的副本已经不在了 —— 可能被从相册里删掉了。';

  @override
  String get syncNothingQueued => '队列为空';

  @override
  String get syncPause => '暂停';

  @override
  String get syncResume => '继续';

  @override
  String syncStart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '开始同步（$count 张）',
    );
    return '$_temp0';
  }

  @override
  String get syncPreviewPausedWhileTransfer => '传输期间取景已暂停。';

  @override
  String get syncLabel => '同步：';

  @override
  String get syncModeAutoPreviewThenOriginal => '自动 —— 先预览图，再原图';

  @override
  String get syncModeAutoOriginalOnly => '自动 —— 只传原图';

  @override
  String get syncModeManualOnly => '手动 —— 只传我选的';

  @override
  String get syncHideList => '收起列表';

  @override
  String syncListCount(int count) {
    return '列表（$count）';
  }

  @override
  String get syncPauseStreamTitle => '同步时暂停取景';

  @override
  String get syncPauseStreamDetail => '两边都最快。关掉它可以继续看取景，代价是传输变慢。';

  @override
  String get syncRawTitle => '同时取回 RAW（每张约 32 MB）';

  @override
  String get syncRawDetail => '每张约 32 MB，而 JPEG 只有 5 MB，还要走相机自己的热点。';

  @override
  String syncRawQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已为列表中 $count 张加上 RAW。不点开始就不会传输。',
    );
    return '$_temp0';
  }

  @override
  String get syncRetryFailed => '重试失败项';

  @override
  String get syncNothingLeftToFetch => '没有待传的照片了。';

  @override
  String syncStillToFetch(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '还有 $count 张待传输',
    );
    return '$_temp0';
  }

  @override
  String syncRemovedFromList(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已从同步列表移除 $count 张，相机上的文件没有被删除。',
    );
    return '$_temp0';
  }

  @override
  String get syncClearList => '清空列表';

  @override
  String get syncRemoveRowNote => '移除一行只是取消这次传输，照片留在相机上，也不会向相机发送任何命令。';

  @override
  String get syncCancelTransfer => '取消这次传输';

  @override
  String get syncRetrying => '重试中…';

  @override
  String get syncStageInFlight => '传输中 —— 本次请求结束后取消';

  @override
  String get syncStagePreviewSaved => '预览图已存，原图待传';

  @override
  String get deleteNothingHereTitle => '这里没有可删除的照片';

  @override
  String deleteConfirmTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '从相机删除 $count 张照片？',
    );
    return '$_temp0';
  }

  @override
  String deleteConfirmBody(int files, String pairs, int requests) {
    String _temp0 = intl.Intl.pluralLogic(
      files,
      locale: localeName,
      other: '这会从相机的 SD 卡上删除 $files 个文件',
    );
    String _temp1 = intl.Intl.pluralLogic(
      requests,
      locale: localeName,
      other: '$requests 次',
    );
    return '$_temp0$pairs，分 $_temp1请求完成。';
  }

  @override
  String deletePairsSuffix(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '（含 $count 组 RAW+JPEG，两部分一起删除）',
    );
    return '$_temp0';
  }

  @override
  String get deleteIrreversibleWarning =>
      '在这个应用里无法撤销：照片不会被预先备份，相机自己不保留副本，这套协议也没有恢复的办法。要留的先同步，再删除。';

  @override
  String get deleteWillNotBeTouched => '不会动这些：';

  @override
  String get deleteKeepThem => '保留';

  @override
  String deleteConfirmAction(int count) {
    return '从相机删除 $count 张';
  }

  @override
  String deleteProgress(int index, int total, String label) {
    return '删除中 —— 第 $index/$total 次请求（$label）';
  }

  @override
  String get deleteNothingSent => '没有向相机发送任何命令。';

  @override
  String get deleteHide => '收起';

  @override
  String get deleteDetails => '详情';

  @override
  String deleteUnconfirmed(int count) {
    return '有 $count 个文件无法确认删除与否 —— 相机接受了请求，但之后列不出存储卡。重新载入相册看看实际还剩什么。';
  }

  @override
  String deleteStillOnCard(int count) {
    return '有 $count 个文件仍在卡上，没有被删除。';
  }

  @override
  String get viewerSaveToPhone => '把这张存到本机';

  @override
  String get viewerQueued => '已加入同步队列，请在相册栏里开始同步。';

  @override
  String get viewerUndecodable => '这张图片无法解码。';

  @override
  String get viewerNotOnPhone => '尚未同步到本机。';

  @override
  String get viewerFetchPreview => '从相机取一张预览图';

  @override
  String get viewerCameraNotConnected => '相机未连接';

  @override
  String get viewerLocalCopy => '正在显示本机保存的副本。';

  @override
  String viewerLoadingFromCamera(String size) {
    return '正在从相机读取 —— $size';
  }

  @override
  String get qualityOriginal => '原图';

  @override
  String get qualityPreview => '仅预览图';

  @override
  String get histogramNoData => '还没有曝光数据';

  @override
  String get histogramUnavailable => '直方图不可用';

  @override
  String get histogramTooltip => '曝光直方图';

  @override
  String histogramStats(String mean, String blown, String crushed) {
    return '平均 $mean$blown$crushed';
  }

  @override
  String histogramBlown(String percent) {
    return '  高光溢出 $percent%';
  }

  @override
  String histogramCrushed(String percent) {
    return '  暗部溢出 $percent%';
  }

  @override
  String get liveConnectionLost => '与相机的连接已断开';

  @override
  String get liveCheckAgain => '再检查一次';

  @override
  String get livePreviewPausedForTransfer => '传输期间取景已暂停';

  @override
  String liveFps(String fps) {
    return '$fps fps';
  }

  @override
  String get liveHideThis => '隐藏这条';

  @override
  String get livePausedBannerBody => '正在拷贝照片。取景和传输共用同一条 Wi-Fi 链路，所以拷贝结束前画面会停住。';

  @override
  String get liveKeepPreviewRunning => '保持取景';

  @override
  String get liveStopPreview => '停止取景';

  @override
  String get liveNoFrames => '无帧';

  @override
  String liveDrawnOfReceivedFps(String drawn, String received) {
    return '$drawn/$received fps';
  }

  @override
  String liveLossPercent(String percent) {
    return '丢帧 $percent%';
  }

  @override
  String get liveCompositionGrid => '构图网格';

  @override
  String get liveFocusAtCentre => '对焦到画面中心';

  @override
  String get liveStartPreview => '开始取景';

  @override
  String get liveStopPreviewTooltip => '停止取景';

  @override
  String get liveFullScreen => '全屏';

  @override
  String get liveExitFullScreen => '退出全屏';

  @override
  String get liveShutterReady => '快门已恢复。';

  @override
  String liveStillBlocked(String reason) {
    return '仍被阻止：$reason';
  }

  @override
  String get liveReleaseAnyway => '仍然解除';

  @override
  String get liveFixShutter => '修复快门';

  @override
  String get liveStartPreviewForSettings => '先开始取景，才能读到相机设置。';

  @override
  String get liveCameraSettings => '相机设置';

  @override
  String get liveHideSettings => '收起设置';

  @override
  String get liveSettings => '设置';

  @override
  String get liveVideoTab => '视频';

  @override
  String get liveAlbumTab => '相册';

  @override
  String get liveEvReference => 'EV 参考';

  @override
  String get liveRetry => '重试';

  @override
  String get liveConnectToCamera => '连接相机';

  @override
  String get joinOutcomeGranted => '已加入。正在寻找相机...';

  @override
  String get joinOutcomeSaved => 'Android 已保存该网络。请允许那条通知，或者在 Wi-Fi 里选择它。';

  @override
  String get joinOutcomeDismissed => '加入提示已被关闭。';

  @override
  String get joinOutcomeTimeout => 'Android 加入超时。';

  @override
  String get liveRetryJoinLabel => '设置';

  @override
  String get liveConnectRetry => '重试';

  @override
  String get liveBleDiagnostics => '蓝牙诊断';

  @override
  String get liveWifiDiagnostics => 'Wi-Fi 诊断';

  @override
  String get liveOpenWifi => '打开 Wi-Fi';

  @override
  String get liveRetryJoin => '重新加入';

  @override
  String get liveAppPermissions => '应用权限';

  @override
  String get liveReRead => '重新读取';

  @override
  String get liveNothingLoggedYet => '（暂无记录）';

  @override
  String get liveBleDiagnosticsBody =>
      '这些属性是相机自己广播的。这里写入失败通常是写入类型或权限不匹配，而不是协议错误。';

  @override
  String get liveWifiDiagnosticsBody =>
      '相机自己不会显示密码，所以在这里读。这里没有猜测：每一行都是刚才在这台手机上实测的。';

  @override
  String get liveCameraAccessPoint => '相机热点';

  @override
  String get liveAccessPointUnknown => '尚不可知 —— 相机打开 Wi-Fi 后，凭据会通过蓝牙传过来。';

  @override
  String get liveSsid => '网络名';

  @override
  String get livePasskey => '密码';

  @override
  String get liveNotReadYet => '（尚未读到）';

  @override
  String get liveOpenedWifiPanel => '已打开 Wi-Fi 面板，请在那里选择相机网络。';

  @override
  String get liveOpenedWifiSettings => '已打开 Wi-Fi 设置，请在那里选择相机网络。';

  @override
  String get liveMeasuredState => '实测状态';

  @override
  String get liveAndroidOnly => '仅 Android —— 当前平台没有可报告的内容。';

  @override
  String get liveLocationServicesOffNote =>
      '定位权限已授予，但定位服务本身是关闭的。Android 会把它报成权限缺失，真正的开关在快捷设置里的定位磁贴 —— 再授予一次权限没有用。';

  @override
  String get diagAndroid => 'Android';

  @override
  String get diagTargetSdk => '目标 SDK';

  @override
  String get diagDevice => '设备';

  @override
  String get diagLocationPermission => '定位权限';

  @override
  String get diagNearbyWifiPermission => '附近 Wi-Fi 权限';

  @override
  String get diagChangeWifiPermission => '更改 Wi-Fi 权限';

  @override
  String get diagChangeNetworkPermission => '更改网络权限';

  @override
  String get diagLocationServices => '定位服务';

  @override
  String get diagWifiRadio => 'Wi-Fi 开关';

  @override
  String get diagNotifications => '通知';

  @override
  String get diagAddNetworkSheet => '“添加网络”弹窗';

  @override
  String get diagGranted => '已授予';

  @override
  String get diagNotGranted => '未授予';

  @override
  String get diagUnknown => '未知';

  @override
  String get diagUnknownValue => '？';

  @override
  String get readoutMode => '模式';

  @override
  String get readoutShutter => '快门';

  @override
  String get readoutAperture => '光圈';

  @override
  String get readoutIso => '感光度';

  @override
  String get readoutIsoAuto => '感光度 自动';

  @override
  String get readoutEv => '曝光补偿';

  @override
  String get readoutWb => '白平衡';

  @override
  String get readoutStyle => '风格';

  @override
  String get readoutBattery => '电量';

  @override
  String get readoutBatteryCharging => '充电中';

  @override
  String get readoutBatteryChargingCompact => '充电';

  @override
  String get readoutLeft => '剩余';

  @override
  String readoutApertureValue(String value) {
    return 'f/$value';
  }

  @override
  String readoutIsoAutoValue(String value) {
    return '感光度 $value（自动）';
  }

  @override
  String readoutIsoValue(String value) {
    return '感光度 $value';
  }

  @override
  String readoutEvValue(String value) {
    return '$value EV';
  }

  @override
  String readoutBatteryAndLeft(String battery, String left) {
    return '$battery%  剩 $left';
  }

  @override
  String readoutBatteryChargingAndLeft(String left) {
    return '充电中  剩 $left';
  }

  @override
  String settingsSetByCamera(String mode) {
    return '在 $mode 档下由相机自己决定 —— 切到 M 档才能调';
  }

  @override
  String get dialAperture => '光圈';

  @override
  String get dialShutter => '快门';

  @override
  String get dialIso => '感光度';

  @override
  String get dialEv => '曝光补偿';

  @override
  String get dialMode => '模式';

  @override
  String dialDecrease(String label) {
    return '调低$label';
  }

  @override
  String dialIncrease(String label) {
    return '调高$label';
  }

  @override
  String get dialDisabledByMode => '不可调';

  @override
  String get albumRawJpgBadge => 'RAW+JPG';

  @override
  String get albumRawBadge => 'RAW';

  @override
  String get albumRawPending => 'RAW 待传';

  @override
  String get albumVideoBadge => 'VIDEO';

  @override
  String get firstRunStepWhatItDoes => '这个应用能做什么';

  @override
  String get firstRunStepHowPhotosCome => '照片怎么传过来';

  @override
  String get firstRunStepPair => '与相机配对';

  @override
  String firstRunStepOf(int step, int total) {
    return '第 $step 步 / 共 $total 步';
  }

  @override
  String get firstRunTitle => '首次使用与配对';

  @override
  String get firstRunSkip => '跳过';

  @override
  String get firstRunClose => '关闭';

  @override
  String get firstRunBack => '上一步';

  @override
  String get firstRunNext => '下一步';

  @override
  String get firstRunStartPairing => '开始配对';

  @override
  String get firstRunPairTryAgain => '重试配对';

  @override
  String get firstRunPairFailedHelp =>
      '这次尝试已经结束，相机那边没有东西在等。把相机开机、放在手边，再按“重试配对”，然后在相机屏幕上按“接受”，几秒内完成。';

  @override
  String get firstRunDone => '完成';

  @override
  String get firstRunIntro =>
      '它通过 Wi-Fi 控制你的小蚁 M1：取景器、快门、相机开放的各项设置，以及把存储卡里的照片拷贝到手机相册。不会向任何服务器发送数据 —— 手机只和相机通信，照片只落到手机上。';

  @override
  String get firstRunWifiOneDeviceTitle => '相机的 Wi-Fi 一次只接一台设备';

  @override
  String get firstRunWifiOneDeviceDetail =>
      '如果电脑或平板已经连上相机，这台手机就连不上。请先断开另一台设备 —— 否则加入失败的样子很像密码错误。';

  @override
  String get firstRunAcceptOnCameraTitle => '配对需要在相机机身上按一下';

  @override
  String get firstRunAcceptOnCameraDetail =>
      '开始配对后，相机会要求确认。你只有几秒钟时间在相机屏幕上按“接受”。已经配对过的电脑会占用这个名额，所以请用你真正要用的那台设备来配对。';

  @override
  String get firstRunSyncIntro => '只问一次，之后记住。以后可以在“同步”页改，或者点顶栏的 ? 重新打开这份指引。';

  @override
  String get firstRunSyncFoot =>
      '预览图很小，几秒就能看到；原图有好几 MB，而链路很慢。这里只决定自动做什么 —— 在相册里你随时可以单张挑选。';

  @override
  String get firstRunSyncAutoPreviewTitle => '自动 —— 先传小预览图，再传原图';

  @override
  String get firstRunSyncAutoPreviewBody => '预览图很小、几秒就出来，所以整张卡很快就能翻完；原图随后跟上。';

  @override
  String get firstRunSyncAutoOriginalTitle => '自动 —— 只传原图';

  @override
  String get firstRunSyncAutoOriginalBody =>
      '落到手机上的每个文件都是真图，但每张都有好几 MB，链路又慢，第一张要等一会儿。';

  @override
  String get firstRunSyncManualTitle => '手动 —— 只传我选的';

  @override
  String get firstRunSyncManualBody =>
      '你不选就不动。只是翻看存储卡不会排入任何传输，在计费网络或慢链路上这样最稳妥。';

  @override
  String get firstRunKeepAwake => '让相机保持开机、不要休眠。如果十秒内没有任何动静，说明相机没收到确认，这次尝试得重来。';

  @override
  String get firstRunKeepAwakeAfterAsk =>
      '让相机保持开机、不要休眠。按下“开始配对”之后如果十秒内没有任何动静，说明相机没收到确认，这次尝试得重来。';

  @override
  String get firstRunFourThings => '按顺序会发生四件事：';

  @override
  String get firstRunPairFind => '通过蓝牙找到相机';

  @override
  String get firstRunPairConfirm => '在相机机身上确认配对';

  @override
  String get firstRunPairAccept => '在相机上按“接受” —— 这一步属于相机，不属于这个应用';

  @override
  String get firstRunPairReadCredentials => '读取相机的 Wi-Fi 名称和密码';

  @override
  String get firstRunPairJoin => '加入该网络，并确认相机有应答';

  @override
  String get firstRunNotConnected => '未连接。按下“开始配对”会让相机要求确认 —— 请把相机开机并放在手边。';

  @override
  String get firstRunConnected => '已连接。“拍摄”页现在有取景、快门和各项设置。';

  @override
  String get videoNotConnected => '尚未连接相机。';

  @override
  String get videoStartPreviewFirst => '请先开始取景 —— 只有在遥控模式下，相机才接受远程命令。';

  @override
  String videoRefusedNotRemote(String label) {
    return '$label被拒绝，因为相机不在遥控模式。请开始取景后重试。';
  }

  @override
  String videoFailed(String label, String detail) {
    return '$label失败：$detail';
  }

  @override
  String videoRejected404(String label) {
    return '$label被拒绝：相机返回 404，在这版固件里意味着该命令或该取值不被这台机身接受。';
  }

  @override
  String get videoStartRecording => '开始录制';

  @override
  String get videoStopRecording => '停止录制';

  @override
  String get videoChangeFormat => '更改格式';

  @override
  String get videoCautionTitle => '遥控视频功能只验证了一部分';

  @override
  String get videoCautionBody =>
      '开始/停止录制和格式命令都已经发给真机并被接受。但还没有任何证据表明视频片段真的写进了 SD 卡，用之前请先检查卡。\n\n防抖、降噪和音频这三项完全没有在真机上验证过：它们是从固件的命令表里读出来的，而表里列出的取值仍然可能被这台机身拒绝。\n\n这台相机没有看门狗，遇到它不预期的命令可能一直无响应，直到取出电池。如果它不再应答，请断电重启。';

  @override
  String get videoNotNow => '暂不';

  @override
  String get videoUnderstandContinue => '我已了解，继续';

  @override
  String get videoPageTitle => '视频录制';

  @override
  String get videoWhatIsVerified => '验证了什么？';

  @override
  String get videoRecordingFormat => '录制格式';

  @override
  String get videoFormatBlockedNote => '录制中不可更改：相机按开始时的格式编码。';

  @override
  String get videoUnavailableUntilPreview => '取景开始后才可用。';

  @override
  String get videoStopRecordingFirst => '请先停止录制再改格式。';

  @override
  String get videoVideoQuality => '视频画质';

  @override
  String get videoElectronicStabilisation => '电子防抖';

  @override
  String get videoNoiseReduction => '降噪';

  @override
  String get videoAudio => '音频';

  @override
  String get videoRecordAudio => '录制声音';

  @override
  String get videoNoStateYet => '还没有相机状态。这些值来自取景流，第一帧到达后才会出现。';

  @override
  String get videoReportedByCamera => '相机报告的值';

  @override
  String get videoRowFormat => '格式';

  @override
  String get videoRowAudio => '音频';

  @override
  String get videoRowVolume => '音量';

  @override
  String get videoRowNoiseReduction => '降噪';

  @override
  String get videoRowStabilisation => '防抖';

  @override
  String videoRequestedNotReported(String format) {
    return '已请求 $format。相机还没有报告该值 —— 在这版固件上，只有取景流算数，所以在上面出现之前都不能算改成功。';
  }

  @override
  String get videoRecordingIndicator => '录制中';

  @override
  String get videoIdle => '待机';

  @override
  String get videoTimerNote => '录制状态和计时由应用自己维护：相机在每一帧里都会报告视频设置，却从不说明它是否正在录制。';

  @override
  String get videoUnknown => '未知';

  @override
  String get videoUnconfirmed => '未确认';

  @override
  String videoRequestedWaiting(String format) {
    return '已请求 $format —— 正在等待相机。';
  }

  @override
  String get videoFormatPoolNote =>
      '这个列表来自固件自己的取值池，各机型共用：某个格式在固件里存在，这台机身仍然可能拒绝。被拒绝时返回 404，并在这里报告。';

  @override
  String get videoStateNotReported => '相机尚未报告状态';

  @override
  String videoSending(String command) {
    return '正在发送 $command...';
  }

  @override
  String get videoVolume => '音量';

  @override
  String get videoNoVolumeYet => '相机还没有报告音量。';

  @override
  String videoCameraReports(String value) {
    return '相机报告 $value。';
  }

  @override
  String get videoChangeInFlight => ' 正在发送更改。';

  @override
  String get videoCautionFoot => '这些命令没有全部在真机上验证过。相机没有看门狗，如果它不再响应，请断电重启。';

  @override
  String get videoOn => '开';

  @override
  String get videoOff => '关';

  @override
  String get linkScanning => '正在寻找相机…';

  @override
  String get linkNotFound => '没有找到相机。相机开机了吗？是不是还被官方 app 占着？';

  @override
  String get linkConnecting => '正在连接…';

  @override
  String get linkReadingIdentity => '正在读取相机标识…';

  @override
  String get linkUnreadableIdentity => '相机返回了无法解析的标识';

  @override
  String linkFound(String firmware, String region) {
    return '找到 $firmware（$region）';
  }

  @override
  String linkReusingPairing(String refId) {
    return '正在复用已保存的配对（refId $refId）…';
  }

  @override
  String linkSavedPairingRejected(String detail) {
    return '已保存的配对没生效（$detail），改为重新配对';
  }

  @override
  String linkPressAllow(String refId) {
    return '现在在相机上按“允许”（refId $refId）';
  }

  @override
  String get linkPairingNotConfirmed => '相机没有确认配对。必须在几秒内于相机屏幕上接受。';

  @override
  String get linkOpeningSession => '正在建立会话…';

  @override
  String get linkEnablingWifi => '正在打开相机的 Wi-Fi…';

  @override
  String get linkReadingCredentials => '正在读取 Wi-Fi 凭据…';

  @override
  String get linkPairingForgotten =>
      '相机拒绝了已保存的配对，已将其遗忘；请再按一次“连接”从头配对（相机会要求确认）。';

  @override
  String get linkNoCredentials => '相机没有交出 Wi-Fi 凭据。会话可能没有被接受。';

  @override
  String linkAskingAndroidToJoin(String ssid) {
    return '正在请求 Android 加入“$ssid”…';
  }

  @override
  String linkJoined(String ssid) {
    return '已加入“$ssid” —— 正在等待相机应答…';
  }

  @override
  String linkJoinedUnbound(String ssid) {
    return '已加入“$ssid” —— 正在等待相机…';
  }

  @override
  String linkSavedNetworkInstead(String ssid, String credential) {
    return 'Android 把“$ssid”存成了网络，而没有直接加入。如果弹出通知，请允许它 —— 否则打开 Wi-Fi 手动选择该网络。密码已经填好（$credential）。';
  }

  @override
  String linkJoinDismissed(String ssid, String credential) {
    return '加入提示被关掉了。点“重新加入”把它调回来，或者自己用密码 $credential 连上“$ssid”。';
  }

  @override
  String linkJoinTimedOut(String ssid) {
    return 'Android 没有在限定时间内完成加入“$ssid”。';
  }

  @override
  String linkJoinUnsupported(String ssid, String credential) {
    return '这台手机不允许应用自行加入“$ssid”，所以打开了 Wi-Fi 界面。请在那里选择“$ssid” —— 密码是 $credential（相机自己不会显示它）。';
  }

  @override
  String linkJoinManual(
      String detail, String ssid, String credential, String permissions) {
    return '$detail 你也可以用密码 $credential 手动连接“$ssid”。[$permissions]';
  }

  @override
  String linkWaitingForCamera(int seconds) {
    return '正在等待相机应答（还剩 $seconds 秒）…';
  }

  @override
  String linkCameraNotAnswering(String host, String ssid, String passkey) {
    return '相机在 $host 上没有应答。请确认手机连的是“$ssid” —— 它的密码是 $passkey —— 然后重试。';
  }

  @override
  String get linkConnected => '已连接';

  @override
  String get linkPreviewRunning => '取景中';

  @override
  String get linkPreviewStopped => '取景已停止';

  @override
  String get linkDisconnected => '已断开';

  @override
  String get linkDisconnectedNoPairing =>
      '已断开，但相机的 Wi-Fi 还开着 —— 相机已经不保存这台手机的配对了，所以 app 没有可用的认证通道去关它。要让它停止广播，请按相机的电源开关，或重新连接后再断开一次。';

  @override
  String get linkDisconnectedRadioRefused =>
      '已断开，但相机的 Wi-Fi 还开着 —— 相机没有确认关机命令。要让它停止广播，请按相机的电源开关，或重新连接后再断开一次。';

  @override
  String get linkDisconnectedNoBle =>
      '已断开，但相机的 Wi-Fi 还开着 —— 与相机的蓝牙连接已经断了，关机命令发不过去。要让它停止广播，请按相机的电源开关，或重新连接后再断开一次。';

  @override
  String get linkIdle => '未连接';

  @override
  String get linkLostContact => '与相机失去联系。它可能被关机了，也可能手机已经离开了相机的 Wi-Fi 网络。';

  @override
  String get stageQueued => '排队中';

  @override
  String get stagePreview => '预览图';

  @override
  String get stageDownloading => '下载中';

  @override
  String get stageStalled => '卡住了，正在重试';

  @override
  String get stagePausedNoCamera => '已暂停，相机不在了';

  @override
  String get stagePausedByUser => '被你暂停';

  @override
  String get stagePausedLowBattery => '已暂停，相机电量低';

  @override
  String get stageDone => '已保存';

  @override
  String get syncNoteCameraAway => '相机不在了。相机回来后同步会自动继续。';

  @override
  String get syncNotePausedByUser => '已被你暂停。';

  @override
  String get syncStreamPauseReason =>
      '传输期间取景已暂停 —— 取景和原图下载共用同一条 Wi-Fi 链路，会互相拖慢。传输一结束就会恢复。';

  @override
  String get deleteRefusalProtected =>
      '相机把这个文件标记为受保护。这个标志在这版固件上究竟意味着什么尚未验证，所以应用把它当作“拒绝删除”处理，而不是去猜 —— 请在相机上解除保护，或者直接在相机上删除它';

  @override
  String deleteRefusalPathTooLong(int length, int limit) {
    return '路径长 $length 个字符，而 DeleteFile 会把每一项拷进 $limit 个字符的槽位，相机因此会截断它，并可能删错文件';
  }

  @override
  String get deleteRefusalListingFailed => '删除之后列不出存储卡，这个文件的去向未知';

  @override
  String albumErrListingRejected(int start, int end) {
    return 'GetFileList 对范围 $start..$end 返回了 404。在这版固件里这意味着参数被拒绝，而不是命令不存在。';
  }

  @override
  String albumErrListingFailed(String raw) {
    return 'GetFileList 失败：$raw';
  }

  @override
  String albumErrPathTooLong(int length, String path) {
    return '路径长 $length 个字符；固件会把它拷进 50 字节的缓冲，所以这个文件永远取不回来：$path';
  }

  @override
  String albumErrDeleteRejected(int count) {
    return 'DeleteFile 对 $count 个路径返回了 404。在这版固件里这意味着请求的结构被拒绝 —— 而不是文件已经没了。';
  }

  @override
  String get albumErrDeleteNoPaths => 'DeleteFile 至少需要一个路径';

  @override
  String albumErrDeleteTooMany(int limit, int count) {
    return 'DeleteFile 每次最多接受 $limit 个路径，这次给了 $count 个；固件会截断列表并悄悄丢掉多余部分，看起来像成功，实际把文件留在了卡上';
  }

  @override
  String get albumErrDeleteAll =>
      '拒绝发送 DeleteFile file_list \"ALL\"：在这版固件里那意味着删除卡上的每一个文件';

  @override
  String albumErrDeletePathTooLong(String path, int length, int limit) {
    return 'DeleteFile 会把每个路径拷进 56 字节的槽位，所以“$path”（$length 个字符）会被截断，可能删错文件；上限是 $limit';
  }

  @override
  String noticeUnwiredRow(String label) {
    return '还没有为“$label”接上任何操作。';
  }

  @override
  String get errStorageDenied =>
      'Android 不允许应用写入相册，所以什么都存不下来。请给本应用授予存储权限，然后重新开始同步。';

  @override
  String get errPreviewRefused => '相机拒绝开始取景';

  @override
  String get noticeShotsNotOnPhone => '这些照片还没有同步到本机。请先同步，或者同步之后再从相机分享。';

  @override
  String get errShareAndroidOnly => '分享功能只在 Android 上实现。';

  @override
  String get errShareSheetRefused => 'Android 没能为这些文件打开分享面板。';

  @override
  String noticeSharedPartially(int missing, int total) {
    return '已分享 $total 张中的 $missing 张，其余的还在同步。';
  }

  @override
  String get noticeShotNotOnPhone => '这张还没有同步到本机。';

  @override
  String get errNoViewerApp => '这台手机上没有任何应用能打开这个文件。';

  @override
  String get errRemoveCopyFailed => '没能删除本机上的副本。';

  @override
  String get errDeleteNotConnected => '尚未连接相机，没有可删除的内容。';

  @override
  String get noticeNothingSentAllRefused => '没有发送任何请求：选中的每一张都是应用拒绝删除的。原因见下方列表。';

  @override
  String get noticeNothingToDelete => '没有可删除的照片。';

  @override
  String errDeleteFailed(String detail) {
    return '删除没能执行：$detail';
  }

  @override
  String get errNotConnectedShort => '未连接';

  @override
  String errCommandFailed(String command, String detail) {
    return '$command 失败：$detail';
  }

  @override
  String errCommandRejected404(String command) {
    return '$command 被拒绝 —— 相机返回 404，在这版固件里意味着参数不对';
  }

  @override
  String errShutterReleaseFailed(String detail) {
    return '快门无法解除：$detail。如果相机已经不再应答，需要断电重启。';
  }

  @override
  String errShutterHealthCheckFailed(String detail) {
    return '相机没有应答健康检查，快门保持锁定：$detail。如果它卡住了，需要断电重启。';
  }

  @override
  String get errInterlockReleasedNoRemote =>
      '互锁已解除，但相机没有重新进入遥控模式。如果它卡住了，请断电重启。';

  @override
  String get errInterlockReleasedStillBlocked => '互锁已解除，但快门仍被阻止。';

  @override
  String get noticeInterlockReleased => '拍摄互锁已解除 —— 快门已恢复。';

  @override
  String get errPhotoFail =>
      '相机拒绝了这次拍摄（“photo fail”）。这意味着它不在遥控模式，或者上一张还在写入存储卡。';

  @override
  String get errCaptureNotReached => '拍摄命令没有到达相机';

  @override
  String get noticeFocusSkippedForShot => '正在拍摄，所以没有发送对焦点。';

  @override
  String errFocusFailed(String detail) {
    return 'RCDoFocus 失败：$detail';
  }

  @override
  String get errFocusRejected404 => 'RCDoFocus 被拒绝 —— 相机返回 404，在这版固件里意味着参数不对';

  @override
  String errUnknownParamCommand(String command) {
    return '未知的参数命令 $command';
  }

  @override
  String errCommandNotInTable(String command) {
    return '$command 不在固件的命令表里';
  }

  @override
  String noticeParamSetByCamera(String mode) {
    return '在 $mode 档下这是相机自己决定的，所以改动没有生效。切到 M 档才能直接控制。';
  }

  @override
  String get shutterBlockedNotConnected => '尚未连接相机。';

  @override
  String get shutterBlockedNotRemote =>
      '相机不在遥控模式，所以不会接受拍摄。请先开始取景 —— 或者按下面的“修复快门”来启动取景。';

  @override
  String shutterBlockedBurst(String drive) {
    return '相机处于$drive驱动模式。一条命令就会开始连拍，而这个应用没有任何办法让它停下 —— 相机会一直拍到自己卡死、必须取出电池。请把驱动模式设为单张，或者直接用相机拍。';
  }

  @override
  String get shutterBlockedQuarantined =>
      '相机拒绝了上一次拍摄，它的拍摄状态现在卡住了 —— 这正是打过补丁的固件所修复的故障。等待不会让它恢复：请给相机断电重启，然后重新连接。';

  @override
  String get settingsTabCapture => '拍摄';

  @override
  String get settingsTabSync => '同步';

  @override
  String get settingsGroupExposure => '曝光与对焦';

  @override
  String get settingsGroupImage => '图像输出';

  @override
  String get settingsGroupImageSummary => '画幅、格式、画质';

  @override
  String get settingsGroupScene => '场景与风格';

  @override
  String get settingsGroupSceneSummary => '色彩风格';

  @override
  String get settingsGroupVideo => '视频与音频';

  @override
  String get settingsGroupVideoSummary => '格式、防抖、降噪、音量';

  @override
  String get settingsGroupTransfer => '传输';

  @override
  String get settingsGroupTransferSummary => '同步模式、传输期间的取景';

  @override
  String get settingsGroupConnection => '连接诊断';

  @override
  String get settingsGroupConnectionSummary => 'Wi-Fi 权限、网络名、密码';

  @override
  String get settingsGroupSystem => '系统与诊断';

  @override
  String get settingsGroupSystemSummary => '息屏时间、蓝牙日志';

  @override
  String get settingsRowRCSwitchDialMode => '曝光模式';

  @override
  String get settingsRowRCISOSet => '感光度';

  @override
  String get settingsRowRCFNSet => '光圈';

  @override
  String get settingsRowRCShutterSpeedSet => '快门';

  @override
  String get settingsRowRCEVSet => '曝光补偿';

  @override
  String get settingsRowRCWBSet => '白平衡';

  @override
  String get settingsRowRCMeteringModeSet => '测光';

  @override
  String get settingsRowRCFocusModeSet => '对焦模式';

  @override
  String get settingsRowRCDriveModeSet => '驱动模式';

  @override
  String get settingsRowRCImageAspect => '画幅';

  @override
  String get settingsRowRCFileFormatSet => '文件格式';

  @override
  String get settingsRowRCImageQualitySet => '画质';

  @override
  String get settingsRowRCChooseColorMode => '色彩风格';

  @override
  String get settingsRowNavVideo => '打开遥控视频';

  @override
  String get settingsRowNavAlbum => '打开同步页';

  @override
  String get settingsRowDiagWifi => 'Wi-Fi 诊断';

  @override
  String get settingsRowDiagBle => '蓝牙诊断';

  @override
  String get settingsRowPauseStream => '传输时暂停取景';

  @override
  String get settingsRowPauseStreamNote =>
      '取景和批量传输共用同一条 802.11n 链路，所以拷贝期间画面会停住，直到传完。';

  @override
  String get settingsRowKeepScreenOn => '取景时保持屏幕常亮';

  @override
  String get settingsRowKeepScreenOnNote =>
      '相机控制器是双手端着、离眼睛一臂远的用法，构图到一半息屏，就只能丢掉这一张重来。';

  @override
  String get settingsRowLocale => '语言';

  @override
  String get localePickerTitle => '语言';

  @override
  String get localePickerNote => '立即生效，并且会记住。';

  @override
  String get localeSystem => '跟随手机';

  @override
  String get localeEnglish => 'English';

  @override
  String get localeChinese => '简体中文';

  @override
  String localeSelected(String name) {
    return '当前：$name';
  }

  @override
  String get paramAuto => '自动';

  @override
  String get paramManual => '手动';

  @override
  String get paramMulti => '多重测光';

  @override
  String get paramSpot => '点测光';

  @override
  String get paramCenterWeighted => '中央重点测光';

  @override
  String get paramCAF => '连续自动对焦';

  @override
  String get paramSAF => '单次自动对焦';

  @override
  String get paramMF => '手动对焦';

  @override
  String get paramSingle => '单张';

  @override
  String get paramContinuous => '连拍';

  @override
  String get paramDelay2s => '2 秒延时';

  @override
  String get paramDelay10s => '10 秒延时';

  @override
  String get paramSunny => '晴天';

  @override
  String get paramCloudy => '多云';

  @override
  String get paramShadow => '阴影';

  @override
  String get paramIncandescent => '白炽灯';

  @override
  String get paramStandard => '标准';

  @override
  String get paramPortrait => '人像';

  @override
  String get paramVivid => '鲜艳';

  @override
  String get paramNaturalBw => '黑白';

  @override
  String get paramHighContrastBw => '高对比黑白';

  @override
  String get paramTime => 'TIME';

  @override
  String get paramBulb => 'B 门';

  @override
  String get paramVga => 'VGA';

  @override
  String get paramJpgSmall => 'JPG 小';

  @override
  String get paramJpgMedium => 'JPG 中';

  @override
  String get paramJpgLarge => 'JPG 大';

  @override
  String get paramRawJpgSmall => 'RAW+JPG 小';

  @override
  String get paramRawJpgMedium => 'RAW+JPG 中';

  @override
  String get paramRawJpgLarge => 'RAW+JPG 大';
}
