import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

// Renders duotone glyphs (both layers); re-exported so screens need one import.
export 'package:phosphor_flutter/phosphor_flutter.dart' show PhosphorIcon;

/// Lumora's icon vocabulary.
///
/// Every icon in the app comes from here, by meaning (`AppIcons.call`), not by
/// glyph. The glyphs are Phosphor Icons (MIT): one consistent 1.5px-stroke
/// family with matching regular / fill / duotone cuts.
///
/// Weights:
///  * the constants below are the **regular** cut - use them for UI chrome
///    (toolbars, nav rail, list trailing icons, buttons);
///  * [duotone] gives the two-tone cut for feature / illustration spots
///    (settings group tiles, empty states, attach menu, onboarding). `IconTile`
///    and `EmptyState` apply it automatically - render duotone glyphs with
///    `PhosphorIcon` (a plain `Icon` drops the secondary layer);
///  * [fill] / the `*Active` constants are for states where "filled" carries
///    meaning: the selected tab, pinned, call controls.
///
/// The trailing comment on each entry is the Lucide icon it replaced (`new`
/// for meanings added with Phosphor).
abstract final class AppIcons {
  // ---------------------------------------------------------------- Navigation & app chrome
  static const IconData close = PhosphorIconsRegular.x; // lucide: x
  static const IconData back = PhosphorIconsRegular.arrowLeft; // lucide: arrowLeft
  static const IconData next = PhosphorIconsRegular.arrowRight; // lucide: arrowRight
  static const IconData chevronRight = PhosphorIconsRegular.caretRight; // lucide: chevronRight
  static const IconData chevronLeft = PhosphorIconsRegular.caretLeft; // lucide: chevronLeft
  static const IconData chevronDown = PhosphorIconsRegular.caretDown; // lucide: chevronDown
  static const IconData chevronsRight = PhosphorIconsRegular.caretDoubleRight; // lucide: chevronsRight
  static const IconData chevronsLeft = PhosphorIconsRegular.caretDoubleLeft; // lucide: chevronsLeft
  static const IconData chevronsDown = PhosphorIconsRegular.caretDoubleDown; // lucide: chevronsDown
  static const IconData more = PhosphorIconsRegular.dotsThree; // lucide: ellipsis
  static const IconData moreVertical = PhosphorIconsRegular.dotsThreeVertical; // lucide: ellipsisVertical
  static const IconData search = PhosphorIconsRegular.magnifyingGlass; // lucide: search
  static const IconData searchEmpty = PhosphorIconsRegular.magnifyingGlassMinus; // lucide: searchX
  static const IconData quickSwitcher = PhosphorIconsRegular.listMagnifyingGlass; // lucide: textSearch
  static const IconData add = PhosphorIconsRegular.plus; // lucide: plus
  static const IconData check = PhosphorIconsRegular.check; // lucide: check
  static const IconData checkDouble = PhosphorIconsRegular.checks; // lucide: checkCheck
  static const IconData checkCircle = PhosphorIconsRegular.checkCircle; // lucide: circleCheck
  static const IconData radioOff = PhosphorIconsRegular.circle; // lucide: circle
  static const IconData radioOn = PhosphorIconsRegular.radioButton; // lucide: circleDot
  static const IconData openExternal = PhosphorIconsRegular.arrowSquareOut; // lucide: externalLink
  static const IconData settings = PhosphorIconsRegular.gearSix; // lucide: settings
  static const IconData sliders = PhosphorIconsRegular.slidersHorizontal; // lucide: slidersHorizontal
  static const IconData density = PhosphorIconsRegular.rows; // lucide: rows3
  static const IconData keypad = PhosphorIconsRegular.dotsNine; // lucide: grip
  static const IconData fullscreen = PhosphorIconsRegular.cornersOut; // lucide: maximize
  static const IconData exitFullscreen = PhosphorIconsRegular.cornersIn; // lucide: minimize
  static const IconData minimize = PhosphorIconsRegular.arrowsIn; // lucide: minimize2
  static const IconData aspectRatio = PhosphorIconsRegular.frameCorners; // lucide: ratio
  static const IconData signIn = PhosphorIconsRegular.signIn; // lucide: logIn
  static const IconData signOut = PhosphorIconsRegular.signOut; // lucide: logOut
  static const IconData clearAll = PhosphorIconsRegular.broom; // lucide: listX
  static const IconData undo = PhosphorIconsRegular.arrowUUpLeft; // lucide: undo2
  static const IconData reset = PhosphorIconsRegular.arrowCounterClockwise; // lucide: rotateCcw
  static const IconData retry = PhosphorIconsRegular.arrowClockwise; // lucide: rotateCw
  static const IconData refresh = PhosphorIconsRegular.arrowsClockwise; // lucide: refreshCw
  static const IconData history = PhosphorIconsRegular.clockCounterClockwise; // lucide: history
  static const IconData transfers = PhosphorIconsRegular.arrowsDownUp; // lucide: arrowDownUp
  static const IconData incoming = PhosphorIconsRegular.arrowDownLeft; // lucide: arrowDownLeft
  static const IconData outgoing = PhosphorIconsRegular.arrowUpRight; // lucide: arrowUpRight
  static const IconData info = PhosphorIconsRegular.info; // lucide: info
  static const IconData sparkle = PhosphorIconsRegular.sparkle; // lucide: sparkles
  static const IconData explore = PhosphorIconsRegular.compass; // lucide: compass

  // ---------------------------------------------------------------- Messaging
  static const IconData chat = PhosphorIconsRegular.chatCircleDots; // lucide: messageCircle
  static const IconData community = PhosphorIconsRegular.chats; // lucide: messagesSquare
  static const IconData newChat = PhosphorIconsRegular.chatCircleText; // lucide: messageCirclePlus
  static const IconData compose = PhosphorIconsRegular.notePencil; // lucide: squarePen
  static const IconData message = PhosphorIconsRegular.chatText; // lucide: messageSquareText
  static const IconData markRead = PhosphorIconsRegular.checks; // lucide: messageSquareCheck
  static const IconData envelopeOpen = PhosphorIconsRegular.envelopeOpen; // lucide: mailOpen
  static const IconData send = PhosphorIconsRegular.paperPlaneRight; // lucide: sendHorizontal
  static const IconData sendTilted = PhosphorIconsRegular.paperPlaneTilt; // lucide: send
  static const IconData reply = PhosphorIconsRegular.arrowBendUpLeft; // lucide: reply
  static const IconData forward = PhosphorIconsRegular.arrowBendUpRight; // lucide: forward
  static const IconData attach = PhosphorIconsRegular.paperclip; // lucide: paperclip
  static const IconData link = PhosphorIconsRegular.link; // lucide: link
  static const IconData mention = PhosphorIconsRegular.at; // lucide: atSign
  static const IconData channel = PhosphorIconsRegular.hash; // lucide: hash
  static const IconData announce = PhosphorIconsRegular.megaphone; // lucide: megaphone
  static const IconData live = PhosphorIconsRegular.broadcast; // lucide: radio
  static const IconData pin = PhosphorIconsRegular.pushPin; // lucide: pin
  static const IconData bookmark = PhosphorIconsRegular.bookmarkSimple; // lucide: bookmark
  static const IconData saveMessage = PhosphorIconsRegular.bookmarks; // lucide: bookmarkPlus
  static const IconData copy = PhosphorIconsRegular.copy; // lucide: copy
  static const IconData paste = PhosphorIconsRegular.clipboard; // lucide: clipboardPaste
  static const IconData clipboard = PhosphorIconsRegular.clipboardText; // lucide: clipboardCopy
  static const IconData clipboardDone = PhosphorIconsRegular.checkSquare; // lucide: clipboardCheck
  static const IconData edit = PhosphorIconsRegular.pencilSimple; // lucide: pencil
  static const IconData delete = PhosphorIconsRegular.trash; // lucide: trash2
  static const IconData archive = PhosphorIconsRegular.archive; // lucide: archive
  static const IconData unarchive = PhosphorIconsRegular.boxArrowUp; // lucide: archiveRestore
  static const IconData emoji = PhosphorIconsRegular.smiley; // lucide: smile
  static const IconData react = PhosphorIconsRegular.smiley; // lucide: smilePlus
  static const IconData meme = PhosphorIconsRegular.smileyWink; // lucide: laugh
  static const IconData sticker = PhosphorIconsRegular.sticker; // lucide: stickyNote
  static const IconData celebrate = PhosphorIconsRegular.confetti; // lucide: partyPopper
  static const IconData poll = PhosphorIconsRegular.chartBarHorizontal; // lucide: chartBar
  static const IconData tasks = PhosphorIconsRegular.listChecks; // lucide: listChecks
  static const IconData addToList = PhosphorIconsRegular.listPlus; // lucide: listPlus
  static const IconData notes = PhosphorIconsRegular.notebook; // lucide: notebookText
  static const IconData contactCard = PhosphorIconsRegular.identificationCard; // lucide: contact
  static const IconData bold = PhosphorIconsRegular.textB; // lucide: bold
  static const IconData italic = PhosphorIconsRegular.textItalic; // lucide: italic
  static const IconData strikethrough = PhosphorIconsRegular.textStrikethrough; // lucide: strikethrough
  static const IconData code = PhosphorIconsRegular.code; // lucide: code
  static const IconData codeBlock = PhosphorIconsRegular.codeBlock; // lucide: squareCode
  static const IconData slashCommand = PhosphorIconsRegular.terminalWindow; // lucide: slashSquare
  static const IconData bell = PhosphorIconsRegular.bell; // lucide: bell
  static const IconData bellRinging = PhosphorIconsRegular.bellRinging; // lucide: bellRing
  static const IconData mute = PhosphorIconsRegular.bellSlash; // lucide: bellOff
  static const IconData timer = PhosphorIconsRegular.timer; // lucide: timer
  static const IconData timerOff = PhosphorIconsRegular.infinity; // lucide: timerOff
  static const IconData timerReset = PhosphorIconsRegular.clockCounterClockwise; // lucide: timerReset
  static const IconData clock = PhosphorIconsRegular.clock; // lucide: clock
  static const IconData hourglass = PhosphorIconsRegular.hourglassMedium; // lucide: hourglass
  static const IconData calendar = PhosphorIconsRegular.calendarBlank; // lucide: calendar
  static const IconData schedule = PhosphorIconsRegular.calendarDots; // lucide: calendarClock
  static const IconData scheduled = PhosphorIconsRegular.calendarCheck; // lucide: calendarCog
  static const IconData reminder = PhosphorIconsRegular.alarm; // lucide: alarmClock
  static const IconData reminderOff = PhosphorIconsRegular.bellSimpleSlash; // lucide: alarmClockOff
  static const IconData reminderDone = PhosphorIconsRegular.checkCircle; // lucide: alarmClockCheck

  // ---------------------------------------------------------------- Calls & media
  static const IconData call = PhosphorIconsRegular.phone; // lucide: phone
  static const IconData hangUp = PhosphorIconsRegular.phoneDisconnect; // lucide: phoneOff
  static const IconData callIncoming = PhosphorIconsRegular.phoneIncoming; // lucide: phoneIncoming
  static const IconData callMissed = PhosphorIconsRegular.phoneX; // lucide: phoneMissed
  static const IconData video = PhosphorIconsRegular.videoCamera; // lucide: video
  static const IconData videoOff = PhosphorIconsRegular.videoCameraSlash; // lucide: videoOff
  static const IconData switchCamera = PhosphorIconsRegular.cameraRotate; // lucide: switchCamera
  static const IconData mic = PhosphorIconsRegular.microphone; // lucide: mic
  static const IconData micOff = PhosphorIconsRegular.microphoneSlash; // lucide: micOff
  static const IconData speaker = PhosphorIconsRegular.speakerHigh; // lucide: volume2
  static const IconData earpiece = PhosphorIconsRegular.ear; // lucide: ear
  static const IconData voice = PhosphorIconsRegular.waveform; // lucide: audioLines
  static const IconData voiceWave = PhosphorIconsRegular.waveform; // lucide: audioWaveform
  static const IconData raiseHand = PhosphorIconsRegular.hand; // lucide: hand
  static const IconData screenShare = PhosphorIconsRegular.monitorArrowUp; // lucide: screenShare
  static const IconData screenShareOff = PhosphorIconsRegular.monitor; // lucide: screenShareOff
  static const IconData cast = PhosphorIconsRegular.screencast; // lucide: cast
  static const IconData presentation = PhosphorIconsRegular.presentation; // lucide: presentation
  static const IconData play = PhosphorIconsRegular.play; // lucide: play
  static const IconData pause = PhosphorIconsRegular.pause; // lucide: pause
  static const IconData stop = PhosphorIconsRegular.stop; // lucide: square
  static const IconData camera = PhosphorIconsRegular.camera; // lucide: camera
  static const IconData image = PhosphorIconsRegular.image; // lucide: image
  static const IconData gallery = PhosphorIconsRegular.images; // lucide: images
  static const IconData addImage = PhosphorIconsRegular.imageSquare; // lucide: imagePlus
  static const IconData imageBroken = PhosphorIconsRegular.imageBroken; // lucide: imageOff
  static const IconData gif = PhosphorIconsRegular.gif; // lucide: imagePlay
  static const IconData film = PhosphorIconsRegular.filmStrip; // lucide: film
  static const IconData music = PhosphorIconsRegular.musicNotes; // lucide: music
  static const IconData wallpaper = PhosphorIconsRegular.paintBrushBroad; // lucide: wallpaper
  static const IconData palette = PhosphorIconsRegular.palette; // lucide: palette
  static const IconData draw = PhosphorIconsRegular.penNib; // lucide: penTool
  static const IconData eraser = PhosphorIconsRegular.eraser; // lucide: eraser
  static const IconData location = PhosphorIconsRegular.mapPin; // lucide: mapPin
  static const IconData map = PhosphorIconsRegular.mapTrifold; // lucide: map
  static const IconData navigate = PhosphorIconsRegular.navigationArrow; // lucide: navigation
  static const IconData locate = PhosphorIconsRegular.gpsFix; // lucide: locateFixed

  // ---------------------------------------------------------------- Files & storage
  static const IconData file = PhosphorIconsRegular.file; // lucide: file
  static const IconData fileText = PhosphorIconsRegular.fileText; // lucide: fileText
  static const IconData fileArchive = PhosphorIconsRegular.fileZip; // lucide: fileArchive
  static const IconData fileUpload = PhosphorIconsRegular.fileArrowUp; // lucide: fileUp
  static const IconData spreadsheet = PhosphorIconsRegular.table; // lucide: sheet
  static const IconData fileCode = PhosphorIconsRegular.fileCode; // lucide: codeXml
  static const IconData diskImage = PhosphorIconsRegular.disc; // lucide: disc
  static const IconData folder = PhosphorIconsRegular.folderOpen; // lucide: folderOpen
  static const IconData download = PhosphorIconsRegular.downloadSimple; // lucide: download
  static const IconData upload = PhosphorIconsRegular.uploadSimple; // lucide: upload
  static const IconData save = PhosphorIconsRegular.floppyDisk; // lucide: save
  static const IconData package = PhosphorIconsRegular.package; // lucide: package
  static const IconData storage = PhosphorIconsRegular.hardDrive; // lucide: hardDrive
  static const IconData backup = PhosphorIconsRegular.boxArrowDown; // lucide: hardDriveDownload
  static const IconData database = PhosphorIconsRegular.database; // lucide: database
  static const IconData clean = PhosphorIconsRegular.broom; // lucide: brushCleaning
  static const IconData guide = PhosphorIconsRegular.bookOpen; // lucide: bookOpen
  static const IconData share = PhosphorIconsRegular.export; // lucide: share2
  static const IconData qrCode = PhosphorIconsRegular.qrCode; // lucide: qrCode

  // ---------------------------------------------------------------- People
  static const IconData friends = PhosphorIconsRegular.usersThree; // lucide: users
  static const IconData people = PhosphorIconsRegular.users; // lucide: usersRound
  static const IconData user = PhosphorIconsRegular.user; // lucide: user
  static const IconData profile = PhosphorIconsRegular.userCircle; // lucide: circleUser
  static const IconData addFriend = PhosphorIconsRegular.userPlus; // lucide: userPlus
  static const IconData removeUser = PhosphorIconsRegular.userMinus; // lucide: userX
  static const IconData owner = PhosphorIconsRegular.crown; // lucide: crown
  static const IconData bot = PhosphorIconsRegular.robot; // lucide: bot
  static const IconData verified = PhosphorIconsRegular.sealCheck; // lucide: badgeCheck

  // ---------------------------------------------------------------- Security & privacy
  static const IconData lock = PhosphorIconsRegular.lock; // lucide: lock
  static const IconData unlock = PhosphorIconsRegular.lockOpen; // lucide: lockOpen
  static const IconData lockKey = PhosphorIconsRegular.lockKey; // lucide: lockKeyhole
  static const IconData key = PhosphorIconsRegular.key; // lucide: keyRound
  static const IconData password = PhosphorIconsRegular.password; // lucide: keySquare
  static const IconData recoveryPhrase = PhosphorIconsRegular.scroll; // lucide: key
  static const IconData fingerprint = PhosphorIconsRegular.fingerprint; // lucide: fingerprint
  static const IconData shield = PhosphorIconsRegular.shield; // lucide: shield
  static const IconData shieldCheck = PhosphorIconsRegular.shieldCheck; // lucide: shieldCheck
  static const IconData shieldPlus = PhosphorIconsRegular.shieldPlus; // lucide: shieldPlus
  static const IconData shieldWarning = PhosphorIconsRegular.shieldWarning; // lucide: shieldAlert
  static const IconData show = PhosphorIconsRegular.eye; // lucide: eye
  static const IconData hide = PhosphorIconsRegular.eyeSlash; // lucide: eyeOff
  static const IconData block = PhosphorIconsRegular.prohibit; // lucide: ban
  static const IconData warning = PhosphorIconsRegular.warning; // lucide: triangleAlert
  static const IconData error = PhosphorIconsRegular.warningCircle; // lucide: circleAlert

  // ---------------------------------------------------------------- Added with Phosphor (no Lucide predecessor)
  static const IconData story = PhosphorIconsRegular.plusCircle; // new
  static const IconData unpin = PhosphorIconsRegular.pushPinSlash; // new

  // ---------------------------------------------------------------- Devices, network & remote
  static const IconData remote = PhosphorIconsRegular.desktop; // lucide: monitor
  static const IconData devices = PhosphorIconsRegular.devices; // lucide: monitorSmartphone
  static const IconData captureOff = PhosphorIconsRegular.monitor; // lucide: monitorOff
  static const IconData captureOn = PhosphorIconsRegular.monitorPlay; // lucide: monitorCheck
  static const IconData laptop = PhosphorIconsRegular.laptop; // lucide: laptop
  static const IconData mobile = PhosphorIconsRegular.deviceMobile; // lucide: smartphone
  static const IconData tablet = PhosphorIconsRegular.deviceTablet; // new
  static const IconData scan = PhosphorIconsRegular.scan; // new: scan a QR code
  static const IconData numpad = PhosphorIconsRegular.numpad; // new: type a numeric code
  static const IconData mouse = PhosphorIconsRegular.mouse; // lucide: mouse
  static const IconData keyboard = PhosphorIconsRegular.keyboard; // lucide: keyboard
  static const IconData command = PhosphorIconsRegular.command; // lucide: command
  static const IconData enterKey = PhosphorIconsRegular.keyReturn; // lucide: cornerDownLeft
  static const IconData backspace = PhosphorIconsRegular.backspace; // lucide: delete
  static const IconData power = PhosphorIconsRegular.power; // lucide: power
  static const IconData server = PhosphorIconsRegular.hardDrives; // lucide: server
  static const IconData lan = PhosphorIconsRegular.network; // lucide: network
  static const IconData router = PhosphorIconsRegular.wifiHigh; // lucide: router
  static const IconData globe = PhosphorIconsRegular.globe; // lucide: globe
  static const IconData peerToPeer = PhosphorIconsRegular.shareNetwork; // lucide: waypoints
  static const IconData direct = PhosphorIconsRegular.lightning; // lucide: zap
  static const IconData relay = PhosphorIconsRegular.cloud; // lucide: cloudCog
  static const IconData offline = PhosphorIconsRegular.cloudSlash; // lucide: cloudOff
  static const IconData activity = PhosphorIconsRegular.pulse; // lucide: activity
  static const IconData quality = PhosphorIconsRegular.gauge; // lucide: gauge
  static const IconData language = PhosphorIconsRegular.translate; // lucide: languages
  static const IconData sun = PhosphorIconsRegular.sun; // lucide: sun
  static const IconData moon = PhosphorIconsRegular.moon; // lucide: moon
  static const IconData themeAuto = PhosphorIconsRegular.circleHalf; // lucide: sunMoon
  static const IconData textSize = PhosphorIconsRegular.textAa; // lucide: aLargeSmall

  // ---------------------------------------------------------------- Camera effects
  /// Beauty / camera effects button and the "beautify on" badge (= [sparkle]).
  static const IconData effects = PhosphorIconsRegular.sparkle; // new
  /// Mirror the sent video ("Lật hình").
  static const IconData mirror = PhosphorIconsRegular.flipHorizontal; // new

  // ---------------------------------------------------------- selected states (fill)
  static const IconData chatActive = PhosphorIconsFill.chatCircleDots; // Chats tab, selected
  static const IconData friendsActive = PhosphorIconsFill.usersThree; // Friends tab, selected
  static const IconData communityActive = PhosphorIconsFill.chats; // Spaces tab, selected
  static const IconData remoteActive = PhosphorIconsFill.desktop; // Remote tab, selected
  static const IconData transfersActive = PhosphorIconsFill.arrowsDownUp; // Files tab, selected
  static const IconData settingsActive = PhosphorIconsFill.gearSix; // Settings tab, selected
  static const IconData pinned = PhosphorIconsFill.pushPin; // pinned chat / message
  static const IconData verifiedFill = PhosphorIconsFill.sealCheck; // verified badge next to a name
  static const IconData hangUpFill = PhosphorIconsFill.phoneDisconnect; // end-call button

  /// Two-tone cut of a regular [AppIcons] glyph (feature / illustration spots).
  /// Returns [icon] unchanged when it is not a regular Phosphor glyph.
  static IconData duotone(IconData icon) => icon.fontFamily == 'PhosphorRegular' ? (_duotone[icon.codePoint] ?? icon) : icon;

  /// Filled cut of a regular [AppIcons] glyph (selected / "on" states).
  static IconData fill(IconData icon) => icon.fontFamily == 'PhosphorRegular' ? (_fill[icon.codePoint] ?? icon) : icon;

  // Lookup tables keyed by the regular glyph's code point. Every value is a
  // const reference so release builds can still tree-shake the icon fonts.
  static final Map<int, IconData> _duotone = {
    0xe4f6: PhosphorIconsDuotone.x,
    0xe058: PhosphorIconsDuotone.arrowLeft,
    0xe06c: PhosphorIconsDuotone.arrowRight,
    0xe13a: PhosphorIconsDuotone.caretRight,
    0xe138: PhosphorIconsDuotone.caretLeft,
    0xe136: PhosphorIconsDuotone.caretDown,
    0xe12a: PhosphorIconsDuotone.caretDoubleRight,
    0xe128: PhosphorIconsDuotone.caretDoubleLeft,
    0xe126: PhosphorIconsDuotone.caretDoubleDown,
    0xe1fe: PhosphorIconsDuotone.dotsThree,
    0xe208: PhosphorIconsDuotone.dotsThreeVertical,
    0xe30c: PhosphorIconsDuotone.magnifyingGlass,
    0xe30e: PhosphorIconsDuotone.magnifyingGlassMinus,
    0xebe0: PhosphorIconsDuotone.listMagnifyingGlass,
    0xe3d4: PhosphorIconsDuotone.plus,
    0xe182: PhosphorIconsDuotone.check,
    0xe53a: PhosphorIconsDuotone.checks,
    0xe184: PhosphorIconsDuotone.checkCircle,
    0xe18a: PhosphorIconsDuotone.circle,
    0xeb08: PhosphorIconsDuotone.radioButton,
    0xe5de: PhosphorIconsDuotone.arrowSquareOut,
    0xe272: PhosphorIconsDuotone.gearSix,
    0xe434: PhosphorIconsDuotone.slidersHorizontal,
    0xe5a2: PhosphorIconsDuotone.rows,
    0xe1fc: PhosphorIconsDuotone.dotsNine,
    0xe1d0: PhosphorIconsDuotone.cornersOut,
    0xe1ce: PhosphorIconsDuotone.cornersIn,
    0xe09a: PhosphorIconsDuotone.arrowsIn,
    0xe626: PhosphorIconsDuotone.frameCorners,
    0xe428: PhosphorIconsDuotone.signIn,
    0xe42a: PhosphorIconsDuotone.signOut,
    0xec54: PhosphorIconsDuotone.broom,
    0xe08a: PhosphorIconsDuotone.arrowUUpLeft,
    0xe038: PhosphorIconsDuotone.arrowCounterClockwise,
    0xe036: PhosphorIconsDuotone.arrowClockwise,
    0xe094: PhosphorIconsDuotone.arrowsClockwise,
    0xe1a0: PhosphorIconsDuotone.clockCounterClockwise,
    0xe098: PhosphorIconsDuotone.arrowsDownUp,
    0xe040: PhosphorIconsDuotone.arrowDownLeft,
    0xe092: PhosphorIconsDuotone.arrowUpRight,
    0xe2ce: PhosphorIconsDuotone.info,
    0xe6a2: PhosphorIconsDuotone.sparkle,
    0xe1c8: PhosphorIconsDuotone.compass,
    0xe16c: PhosphorIconsDuotone.chatCircleDots,
    0xe17c: PhosphorIconsDuotone.chats,
    0xe16e: PhosphorIconsDuotone.chatCircleText,
    0xe34c: PhosphorIconsDuotone.notePencil,
    0xe17a: PhosphorIconsDuotone.chatText,
    0xe216: PhosphorIconsDuotone.envelopeOpen,
    0xe396: PhosphorIconsDuotone.paperPlaneRight,
    0xe398: PhosphorIconsDuotone.paperPlaneTilt,
    0xe024: PhosphorIconsDuotone.arrowBendUpLeft,
    0xe026: PhosphorIconsDuotone.arrowBendUpRight,
    0xe39a: PhosphorIconsDuotone.paperclip,
    0xe2e2: PhosphorIconsDuotone.link,
    0xe0ac: PhosphorIconsDuotone.at,
    0xe2a2: PhosphorIconsDuotone.hash,
    0xe324: PhosphorIconsDuotone.megaphone,
    0xe0f2: PhosphorIconsDuotone.broadcast,
    0xe3e2: PhosphorIconsDuotone.pushPin,
    0xe0ea: PhosphorIconsDuotone.bookmarkSimple,
    0xe0ec: PhosphorIconsDuotone.bookmarks,
    0xe1ca: PhosphorIconsDuotone.copy,
    0xe196: PhosphorIconsDuotone.clipboard,
    0xe198: PhosphorIconsDuotone.clipboardText,
    0xe186: PhosphorIconsDuotone.checkSquare,
    0xe3b4: PhosphorIconsDuotone.pencilSimple,
    0xe4a6: PhosphorIconsDuotone.trash,
    0xe00c: PhosphorIconsDuotone.archive,
    0xee54: PhosphorIconsDuotone.boxArrowUp,
    0xe436: PhosphorIconsDuotone.smiley,
    0xe666: PhosphorIconsDuotone.smileyWink,
    0xe5ac: PhosphorIconsDuotone.sticker,
    0xe81a: PhosphorIconsDuotone.confetti,
    0xe152: PhosphorIconsDuotone.chartBarHorizontal,
    0xeadc: PhosphorIconsDuotone.listChecks,
    0xe2f8: PhosphorIconsDuotone.listPlus,
    0xe34e: PhosphorIconsDuotone.notebook,
    0xe2c8: PhosphorIconsDuotone.identificationCard,
    0xe5be: PhosphorIconsDuotone.textB,
    0xe5c0: PhosphorIconsDuotone.textItalic,
    0xe5c2: PhosphorIconsDuotone.textStrikethrough,
    0xe1bc: PhosphorIconsDuotone.code,
    0xeafe: PhosphorIconsDuotone.codeBlock,
    0xeae8: PhosphorIconsDuotone.terminalWindow,
    0xe1e6: PhosphorIconsDuotone.deviceTablet,
    0xebb6: PhosphorIconsDuotone.scan,
    0xe3c8: PhosphorIconsDuotone.numpad,
    0xe0ce: PhosphorIconsDuotone.bell,
    0xe5e8: PhosphorIconsDuotone.bellRinging,
    0xe0d4: PhosphorIconsDuotone.bellSlash,
    0xe492: PhosphorIconsDuotone.timer,
    0xe634: PhosphorIconsDuotone.infinity,
    0xe19a: PhosphorIconsDuotone.clock,
    0xe2b8: PhosphorIconsDuotone.hourglassMedium,
    0xe10a: PhosphorIconsDuotone.calendarBlank,
    0xe7b4: PhosphorIconsDuotone.calendarDots,
    0xe712: PhosphorIconsDuotone.calendarCheck,
    0xe006: PhosphorIconsDuotone.alarm,
    0xe0d2: PhosphorIconsDuotone.bellSimpleSlash,
    0xe3b8: PhosphorIconsDuotone.phone,
    0xe3bc: PhosphorIconsDuotone.phoneDisconnect,
    0xe3be: PhosphorIconsDuotone.phoneIncoming,
    0xe3c4: PhosphorIconsDuotone.phoneX,
    0xe4da: PhosphorIconsDuotone.videoCamera,
    0xe4dc: PhosphorIconsDuotone.videoCameraSlash,
    0xe326: PhosphorIconsDuotone.microphone,
    0xe328: PhosphorIconsDuotone.microphoneSlash,
    0xe44a: PhosphorIconsDuotone.speakerHigh,
    0xe70c: PhosphorIconsDuotone.ear,
    0xe802: PhosphorIconsDuotone.waveform,
    0xe298: PhosphorIconsDuotone.hand,
    0xe58a: PhosphorIconsDuotone.monitorArrowUp,
    0xe32e: PhosphorIconsDuotone.monitor,
    0xe404: PhosphorIconsDuotone.screencast,
    0xe654: PhosphorIconsDuotone.presentation,
    0xe3d0: PhosphorIconsDuotone.play,
    0xe39e: PhosphorIconsDuotone.pause,
    0xe46c: PhosphorIconsDuotone.stop,
    0xe10e: PhosphorIconsDuotone.camera,
    0xe2ca: PhosphorIconsDuotone.image,
    0xe836: PhosphorIconsDuotone.images,
    0xe2cc: PhosphorIconsDuotone.imageSquare,
    0xe7a8: PhosphorIconsDuotone.imageBroken,
    0xe274: PhosphorIconsDuotone.gif,
    0xe792: PhosphorIconsDuotone.filmStrip,
    0xe340: PhosphorIconsDuotone.musicNotes,
    0xe590: PhosphorIconsDuotone.paintBrushBroad,
    0xe6c8: PhosphorIconsDuotone.palette,
    0xe3ac: PhosphorIconsDuotone.penNib,
    0xe21e: PhosphorIconsDuotone.eraser,
    0xe316: PhosphorIconsDuotone.mapPin,
    0xe31a: PhosphorIconsDuotone.mapTrifold,
    0xeade: PhosphorIconsDuotone.navigationArrow,
    0xedd6: PhosphorIconsDuotone.gpsFix,
    0xe230: PhosphorIconsDuotone.file,
    0xe23a: PhosphorIconsDuotone.fileText,
    0xe958: PhosphorIconsDuotone.fileZip,
    0xe61e: PhosphorIconsDuotone.fileArrowUp,
    0xe476: PhosphorIconsDuotone.table,
    0xe914: PhosphorIconsDuotone.fileCode,
    0xe564: PhosphorIconsDuotone.disc,
    0xe256: PhosphorIconsDuotone.folderOpen,
    0xe20c: PhosphorIconsDuotone.downloadSimple,
    0xe4c0: PhosphorIconsDuotone.uploadSimple,
    0xe248: PhosphorIconsDuotone.floppyDisk,
    0xe390: PhosphorIconsDuotone.package,
    0xe29e: PhosphorIconsDuotone.hardDrive,
    0xe00e: PhosphorIconsDuotone.boxArrowDown,
    0xe1de: PhosphorIconsDuotone.database,
    0xe0e6: PhosphorIconsDuotone.bookOpen,
    0xeaf0: PhosphorIconsDuotone.export,
    0xe3e6: PhosphorIconsDuotone.qrCode,
    0xe68e: PhosphorIconsDuotone.usersThree,
    0xe4d6: PhosphorIconsDuotone.users,
    0xe4c2: PhosphorIconsDuotone.user,
    0xe4c4: PhosphorIconsDuotone.userCircle,
    0xe4d0: PhosphorIconsDuotone.userPlus,
    0xe4ce: PhosphorIconsDuotone.userMinus,
    0xe614: PhosphorIconsDuotone.crown,
    0xe762: PhosphorIconsDuotone.robot,
    0xe606: PhosphorIconsDuotone.sealCheck,
    0xe2fa: PhosphorIconsDuotone.lock,
    0xe306: PhosphorIconsDuotone.lockOpen,
    0xe2fe: PhosphorIconsDuotone.lockKey,
    0xe2d6: PhosphorIconsDuotone.key,
    0xe752: PhosphorIconsDuotone.password,
    0xeb7a: PhosphorIconsDuotone.scroll,
    0xe23e: PhosphorIconsDuotone.fingerprint,
    0xe40a: PhosphorIconsDuotone.shield,
    0xe40c: PhosphorIconsDuotone.shieldCheck,
    0xe706: PhosphorIconsDuotone.shieldPlus,
    0xe412: PhosphorIconsDuotone.shieldWarning,
    0xe220: PhosphorIconsDuotone.eye,
    0xe224: PhosphorIconsDuotone.eyeSlash,
    0xe3de: PhosphorIconsDuotone.prohibit,
    0xe4e0: PhosphorIconsDuotone.warning,
    0xe4e2: PhosphorIconsDuotone.warningCircle,
    0xe3d6: PhosphorIconsDuotone.plusCircle,
    0xe3e4: PhosphorIconsDuotone.pushPinSlash,
    0xe560: PhosphorIconsDuotone.desktop,
    0xeba4: PhosphorIconsDuotone.devices,
    0xe58c: PhosphorIconsDuotone.monitorPlay,
    0xe586: PhosphorIconsDuotone.laptop,
    0xe1e0: PhosphorIconsDuotone.deviceMobile,
    0xe33a: PhosphorIconsDuotone.mouse,
    0xe2d8: PhosphorIconsDuotone.keyboard,
    0xe1c4: PhosphorIconsDuotone.command,
    0xe782: PhosphorIconsDuotone.keyReturn,
    0xe0ae: PhosphorIconsDuotone.backspace,
    0xe3da: PhosphorIconsDuotone.power,
    0xe2a0: PhosphorIconsDuotone.hardDrives,
    0xedde: PhosphorIconsDuotone.network,
    0xe4ea: PhosphorIconsDuotone.wifiHigh,
    0xe288: PhosphorIconsDuotone.globe,
    0xe408: PhosphorIconsDuotone.shareNetwork,
    0xe2de: PhosphorIconsDuotone.lightning,
    0xe1aa: PhosphorIconsDuotone.cloud,
    0xe1b6: PhosphorIconsDuotone.cloudSlash,
    0xe000: PhosphorIconsDuotone.pulse,
    0xe628: PhosphorIconsDuotone.gauge,
    0xe4a2: PhosphorIconsDuotone.translate,
    0xe472: PhosphorIconsDuotone.sun,
    0xed6a: PhosphorIconsDuotone.flipHorizontal,
    0xe330: PhosphorIconsDuotone.moon,
    0xe18c: PhosphorIconsDuotone.circleHalf,
  };

  static final Map<int, IconData> _fill = {
    0xe4f6: PhosphorIconsFill.x,
    0xe058: PhosphorIconsFill.arrowLeft,
    0xe06c: PhosphorIconsFill.arrowRight,
    0xe13a: PhosphorIconsFill.caretRight,
    0xe138: PhosphorIconsFill.caretLeft,
    0xe136: PhosphorIconsFill.caretDown,
    0xe12a: PhosphorIconsFill.caretDoubleRight,
    0xe128: PhosphorIconsFill.caretDoubleLeft,
    0xe126: PhosphorIconsFill.caretDoubleDown,
    0xe30c: PhosphorIconsFill.magnifyingGlass,
    0xe30e: PhosphorIconsFill.magnifyingGlassMinus,
    0xebe0: PhosphorIconsFill.listMagnifyingGlass,
    0xe3d4: PhosphorIconsFill.plus,
    0xe182: PhosphorIconsFill.check,
    0xe53a: PhosphorIconsFill.checks,
    0xe184: PhosphorIconsFill.checkCircle,
    0xe18a: PhosphorIconsFill.circle,
    0xeb08: PhosphorIconsFill.radioButton,
    0xe5de: PhosphorIconsFill.arrowSquareOut,
    0xe272: PhosphorIconsFill.gearSix,
    0xe434: PhosphorIconsFill.slidersHorizontal,
    0xe5a2: PhosphorIconsFill.rows,
    0xe1fc: PhosphorIconsFill.dotsNine,
    0xe1d0: PhosphorIconsFill.cornersOut,
    0xe1ce: PhosphorIconsFill.cornersIn,
    0xe09a: PhosphorIconsFill.arrowsIn,
    0xe626: PhosphorIconsFill.frameCorners,
    0xe428: PhosphorIconsFill.signIn,
    0xe42a: PhosphorIconsFill.signOut,
    0xec54: PhosphorIconsFill.broom,
    0xe08a: PhosphorIconsFill.arrowUUpLeft,
    0xe038: PhosphorIconsFill.arrowCounterClockwise,
    0xe036: PhosphorIconsFill.arrowClockwise,
    0xe094: PhosphorIconsFill.arrowsClockwise,
    0xe1a0: PhosphorIconsFill.clockCounterClockwise,
    0xe098: PhosphorIconsFill.arrowsDownUp,
    0xe040: PhosphorIconsFill.arrowDownLeft,
    0xe092: PhosphorIconsFill.arrowUpRight,
    0xe2ce: PhosphorIconsFill.info,
    0xe6a2: PhosphorIconsFill.sparkle,
    0xe1c8: PhosphorIconsFill.compass,
    0xe16c: PhosphorIconsFill.chatCircleDots,
    0xe17c: PhosphorIconsFill.chats,
    0xe16e: PhosphorIconsFill.chatCircleText,
    0xe34c: PhosphorIconsFill.notePencil,
    0xe17a: PhosphorIconsFill.chatText,
    0xe216: PhosphorIconsFill.envelopeOpen,
    0xe396: PhosphorIconsFill.paperPlaneRight,
    0xe398: PhosphorIconsFill.paperPlaneTilt,
    0xe024: PhosphorIconsFill.arrowBendUpLeft,
    0xe026: PhosphorIconsFill.arrowBendUpRight,
    0xe39a: PhosphorIconsFill.paperclip,
    0xe2e2: PhosphorIconsFill.link,
    0xe0ac: PhosphorIconsFill.at,
    0xe2a2: PhosphorIconsFill.hash,
    0xe324: PhosphorIconsFill.megaphone,
    0xe0f2: PhosphorIconsFill.broadcast,
    0xe3e2: PhosphorIconsFill.pushPin,
    0xe0ea: PhosphorIconsFill.bookmarkSimple,
    0xe0ec: PhosphorIconsFill.bookmarks,
    0xe1ca: PhosphorIconsFill.copy,
    0xe196: PhosphorIconsFill.clipboard,
    0xe198: PhosphorIconsFill.clipboardText,
    0xe186: PhosphorIconsFill.checkSquare,
    0xe3b4: PhosphorIconsFill.pencilSimple,
    0xe4a6: PhosphorIconsFill.trash,
    0xe00c: PhosphorIconsFill.archive,
    0xee54: PhosphorIconsFill.boxArrowUp,
    0xe436: PhosphorIconsFill.smiley,
    0xe666: PhosphorIconsFill.smileyWink,
    0xe5ac: PhosphorIconsFill.sticker,
    0xe81a: PhosphorIconsFill.confetti,
    0xe152: PhosphorIconsFill.chartBarHorizontal,
    0xeadc: PhosphorIconsFill.listChecks,
    0xe2f8: PhosphorIconsFill.listPlus,
    0xe34e: PhosphorIconsFill.notebook,
    0xe2c8: PhosphorIconsFill.identificationCard,
    0xe5be: PhosphorIconsFill.textB,
    0xe5c0: PhosphorIconsFill.textItalic,
    0xe5c2: PhosphorIconsFill.textStrikethrough,
    0xe1bc: PhosphorIconsFill.code,
    0xeafe: PhosphorIconsFill.codeBlock,
    0xeae8: PhosphorIconsFill.terminalWindow,
    0xe0ce: PhosphorIconsFill.bell,
    0xe5e8: PhosphorIconsFill.bellRinging,
    0xe0d4: PhosphorIconsFill.bellSlash,
    0xe492: PhosphorIconsFill.timer,
    0xe634: PhosphorIconsFill.infinity,
    0xe19a: PhosphorIconsFill.clock,
    0xe2b8: PhosphorIconsFill.hourglassMedium,
    0xe10a: PhosphorIconsFill.calendarBlank,
    0xe7b4: PhosphorIconsFill.calendarDots,
    0xe712: PhosphorIconsFill.calendarCheck,
    0xe006: PhosphorIconsFill.alarm,
    0xe0d2: PhosphorIconsFill.bellSimpleSlash,
    0xe3b8: PhosphorIconsFill.phone,
    0xe3bc: PhosphorIconsFill.phoneDisconnect,
    0xe3be: PhosphorIconsFill.phoneIncoming,
    0xe3c4: PhosphorIconsFill.phoneX,
    0xe4da: PhosphorIconsFill.videoCamera,
    0xe4dc: PhosphorIconsFill.videoCameraSlash,
    0xe326: PhosphorIconsFill.microphone,
    0xe328: PhosphorIconsFill.microphoneSlash,
    0xe44a: PhosphorIconsFill.speakerHigh,
    0xe70c: PhosphorIconsFill.ear,
    0xe802: PhosphorIconsFill.waveform,
    0xe298: PhosphorIconsFill.hand,
    0xe58a: PhosphorIconsFill.monitorArrowUp,
    0xe32e: PhosphorIconsFill.monitor,
    0xe404: PhosphorIconsFill.screencast,
    0xe654: PhosphorIconsFill.presentation,
    0xe3d0: PhosphorIconsFill.play,
    0xe39e: PhosphorIconsFill.pause,
    0xe46c: PhosphorIconsFill.stop,
    0xe10e: PhosphorIconsFill.camera,
    0xe2ca: PhosphorIconsFill.image,
    0xe836: PhosphorIconsFill.images,
    0xe2cc: PhosphorIconsFill.imageSquare,
    0xe7a8: PhosphorIconsFill.imageBroken,
    0xe274: PhosphorIconsFill.gif,
    0xe792: PhosphorIconsFill.filmStrip,
    0xe340: PhosphorIconsFill.musicNotes,
    0xe590: PhosphorIconsFill.paintBrushBroad,
    0xe6c8: PhosphorIconsFill.palette,
    0xe3ac: PhosphorIconsFill.penNib,
    0xe21e: PhosphorIconsFill.eraser,
    0xe316: PhosphorIconsFill.mapPin,
    0xe31a: PhosphorIconsFill.mapTrifold,
    0xeade: PhosphorIconsFill.navigationArrow,
    0xedd6: PhosphorIconsFill.gpsFix,
    0xe230: PhosphorIconsFill.file,
    0xe23a: PhosphorIconsFill.fileText,
    0xe958: PhosphorIconsFill.fileZip,
    0xe61e: PhosphorIconsFill.fileArrowUp,
    0xe476: PhosphorIconsFill.table,
    0xe914: PhosphorIconsFill.fileCode,
    0xe564: PhosphorIconsFill.disc,
    0xe256: PhosphorIconsFill.folderOpen,
    0xe20c: PhosphorIconsFill.downloadSimple,
    0xe4c0: PhosphorIconsFill.uploadSimple,
    0xe248: PhosphorIconsFill.floppyDisk,
    0xe390: PhosphorIconsFill.package,
    0xe29e: PhosphorIconsFill.hardDrive,
    0xe00e: PhosphorIconsFill.boxArrowDown,
    0xe1de: PhosphorIconsFill.database,
    0xe0e6: PhosphorIconsFill.bookOpen,
    0xeaf0: PhosphorIconsFill.export,
    0xe3e6: PhosphorIconsFill.qrCode,
    0xe68e: PhosphorIconsFill.usersThree,
    0xe4d6: PhosphorIconsFill.users,
    0xe4c2: PhosphorIconsFill.user,
    0xe4c4: PhosphorIconsFill.userCircle,
    0xe4d0: PhosphorIconsFill.userPlus,
    0xe4ce: PhosphorIconsFill.userMinus,
    0xe614: PhosphorIconsFill.crown,
    0xe762: PhosphorIconsFill.robot,
    0xe606: PhosphorIconsFill.sealCheck,
    0xe2fa: PhosphorIconsFill.lock,
    0xe306: PhosphorIconsFill.lockOpen,
    0xe2fe: PhosphorIconsFill.lockKey,
    0xe2d6: PhosphorIconsFill.key,
    0xe752: PhosphorIconsFill.password,
    0xeb7a: PhosphorIconsFill.scroll,
    0xe23e: PhosphorIconsFill.fingerprint,
    0xe40a: PhosphorIconsFill.shield,
    0xe40c: PhosphorIconsFill.shieldCheck,
    0xe706: PhosphorIconsFill.shieldPlus,
    0xe412: PhosphorIconsFill.shieldWarning,
    0xe220: PhosphorIconsFill.eye,
    0xe224: PhosphorIconsFill.eyeSlash,
    0xe3de: PhosphorIconsFill.prohibit,
    0xe4e0: PhosphorIconsFill.warning,
    0xe4e2: PhosphorIconsFill.warningCircle,
    0xe3d6: PhosphorIconsFill.plusCircle,
    0xe3e4: PhosphorIconsFill.pushPinSlash,
    0xe560: PhosphorIconsFill.desktop,
    0xeba4: PhosphorIconsFill.devices,
    0xe58c: PhosphorIconsFill.monitorPlay,
    0xe586: PhosphorIconsFill.laptop,
    0xe1e0: PhosphorIconsFill.deviceMobile,
    0xe33a: PhosphorIconsFill.mouse,
    0xe2d8: PhosphorIconsFill.keyboard,
    0xe1c4: PhosphorIconsFill.command,
    0xe782: PhosphorIconsFill.keyReturn,
    0xe0ae: PhosphorIconsFill.backspace,
    0xe3da: PhosphorIconsFill.power,
    0xe2a0: PhosphorIconsFill.hardDrives,
    0xedde: PhosphorIconsFill.network,
    0xe4ea: PhosphorIconsFill.wifiHigh,
    0xe288: PhosphorIconsFill.globe,
    0xe408: PhosphorIconsFill.shareNetwork,
    0xe2de: PhosphorIconsFill.lightning,
    0xe1aa: PhosphorIconsFill.cloud,
    0xe1b6: PhosphorIconsFill.cloudSlash,
    0xe000: PhosphorIconsFill.pulse,
    0xe628: PhosphorIconsFill.gauge,
    0xe4a2: PhosphorIconsFill.translate,
    0xe472: PhosphorIconsFill.sun,
    0xe330: PhosphorIconsFill.moon,
    0xe18c: PhosphorIconsFill.circleHalf,
    0xed6a: PhosphorIconsFill.flipHorizontal,
  };
}
