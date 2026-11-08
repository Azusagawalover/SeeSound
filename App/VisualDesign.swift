import SwiftUI
import ImageIO

enum SeeArtwork:String,CaseIterable {
    case campus,speech,clipboard,calendar,folder,shield,headphone,compass,memo,books,watch,search
    var symbol:String {
        switch self {
        case .campus:return "building.2";case .speech:return "bubble.left.and.bubble.right"
        case .clipboard:return "checklist";case .calendar:return "calendar";case .folder:return "folder"
        case .shield:return "heart.text.square";case .headphone:return "headphones";case .compass:return "location.north"
        case .memo:return "note.text";case .books:return "book";case .watch:return "applewatch";case .search:return "doc.text.viewfinder"
        }
    }
    var wash:Color {
        switch self { case .speech:return SeePalette.sage;case .headphone:return SeePalette.lilac;case .calendar,.memo,.books:return SeePalette.oat;case .search,.watch:return SeePalette.sky;default:return SeePalette.rose }
    }
    private var illustration:String {
        switch self { case .headphone:return "dancing";case .shield:return "loving";case .folder:return "unboxing";case .speech,.watch:return "sitting";case .compass:return "strolling";case .memo:return "coffee";default:return "reading-side" }
    }
    private static let images:[String:UIImage] = {
        var result:[String:UIImage] = [:]
        for name in ["reading-side","dancing","loving","unboxing","coffee","strolling","sitting"] {
            if let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:"JournalAssets"),
               let source = CGImageSourceCreateWithURL(url as CFURL,nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:480,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) { result[name] = UIImage(cgImage:cg) }
        }
        return result
    }()
    var image:UIImage? { Self.images[illustration] }
    static func forSymbol(_ symbol:String) -> SeeArtwork {
        if symbol.contains("watch") { return .watch }
        if symbol.contains("folder") || symbol.contains("tray") { return .folder }
        if symbol.contains("building") { return .campus }
        if symbol.contains("location") || symbol.contains("compass") { return .compass }
        if symbol.contains("magnifyingglass") || symbol.contains("viewfinder") { return .search }
        if symbol.contains("calendar") || symbol.contains("clock") { return .calendar }
        if symbol.contains("person.2") || symbol.contains("bubble") || symbol.contains("captions") { return .speech }
        if symbol.contains("waveform") || symbol.contains("ear") || symbol.contains("mic") { return .headphone }
        if symbol.contains("shield") || symbol.contains("lock") || symbol.contains("heart") { return .shield }
        if symbol.contains("doc") || symbol.contains("arrow.triangle") { return .folder }
        if symbol.contains("questionmark") || symbol.contains("book") { return .books }
        if symbol.contains("check") || symbol.contains("rectangle.stack") { return .clipboard }
        if symbol.contains("sparkles") || symbol.contains("point.") { return .compass }
        return .memo
    }
}

enum SeePalette {
    private static func adaptive(_ light:UInt32,_ dark:UInt32) -> Color {
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red:CGFloat((value >> 16) & 255)/255,green:CGFloat((value >> 8) & 255)/255,blue:CGFloat(value & 255)/255,alpha:1)
        })
    }
    static let canvas = adaptive(0xF2E3E8,0x2B2228)
    static let surface = adaptive(0xFFFCF7,0x362C30)
    static let ink = adaptive(0x514347,0xF9EBE1)
    static let secondary = adaptive(0x79646A,0xD7BDC5)
    static let line = adaptive(0xE3D1D8,0x604A53)
    static let rose = adaptive(0xF3C6D1,0x573341)
    static let sage = adaptive(0xD7E8BE,0x343F2D)
    static let oat = adaptive(0xF6E4A9,0x4B3E29)
    static let sky = adaptive(0xCFE5F2,0x2E3D4A)
    static let lilac = adaptive(0xE5D8F4,0x43364F)
    static let soft = rose
    static let button = Color(red:0.56,green:0.28,blue:0.40)
    static let forest = button
    static let teal = Color(red:0.56,green:0.28,blue:0.40)
    static let warm = oat
}

private struct JournalRuling:Shape {
    func path(in rect:CGRect) -> Path {
        var path = Path()
        for y in stride(from:CGFloat(30),to:rect.height,by:28) { path.move(to:CGPoint(x:0,y:y));path.addLine(to:CGPoint(x:rect.width,y:y)) }
        return path
    }
}

extension View {
    func seeTabCanvas() -> some View {
        toolbarBackground(SeePalette.canvas,for:.tabBar)
            .toolbarBackground(.visible,for:.tabBar)
    }
    func seePageCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(SeePalette.canvas)
            .toolbarBackground(SeePalette.canvas,for:.navigationBar)
            .toolbarBackground(.visible,for:.navigationBar)
    }
}

struct SeeArtworkView:View {
    let artwork:SeeArtwork
    var size:CGFloat = 80
    var body:some View {
        Group {
            if size >= 70,let image = artwork.image {
                Image(uiImage:image).resizable().interpolation(.high).scaledToFit().saturation(0.75).opacity(0.9).padding(5)
                    .background(Color(red:1,green:0.97,blue:0.89),in:RoundedRectangle(cornerRadius:24))
            } else {
                JournalFeatureIcon(artwork:artwork)
            }
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

private struct JournalFeatureIcon:View {
    let artwork:SeeArtwork
    var body:some View {
        Canvas { context,size in
            context.scaleBy(x:size.width/64,y:size.height/64)
            func fill(_ path:Path,_ color:Color) { context.fill(path,with:.color(color)) }
            func stroke(_ path:Path) { context.stroke(path,with:.color(SeePalette.ink),style:StrokeStyle(lineWidth:2.6,lineCap:.round,lineJoin:.round)) }
            fill(Path(roundedRect:CGRect(x:2,y:2,width:60,height:60),cornerRadius:19),artwork.wash.opacity(0.7))
            switch artwork {
            case .search:
                var page = Path()
                page.move(to:CGPoint(x:20,y:10));page.addLine(to:CGPoint(x:36,y:10));page.addLine(to:CGPoint(x:47,y:21));page.addLine(to:CGPoint(x:47,y:49))
                page.addQuadCurve(to:CGPoint(x:43,y:53),control:CGPoint(x:47,y:53));page.addLine(to:CGPoint(x:20,y:53))
                page.addQuadCurve(to:CGPoint(x:16,y:49),control:CGPoint(x:16,y:53));page.addLine(to:CGPoint(x:16,y:14))
                page.addQuadCurve(to:CGPoint(x:20,y:10),control:CGPoint(x:16,y:10));page.closeSubpath()
                fill(page,SeePalette.surface);stroke(page)
                var fold = Path()
                fold.move(to:CGPoint(x:36,y:10));fold.addLine(to:CGPoint(x:36,y:18));fold.addQuadCurve(to:CGPoint(x:39,y:21),control:CGPoint(x:36,y:21));fold.addLine(to:CGPoint(x:47,y:21));fold.closeSubpath()
                fill(fold,SeePalette.rose);stroke(fold)
                var lines = Path()
                for (y,end) in [(29,39),(35,39),(41,33)] { lines.move(to:CGPoint(x:23,y:y));lines.addLine(to:CGPoint(x:end,y:y)) }
                stroke(lines)
                let badge = Path(ellipseIn:CGRect(x:7,y:39,width:20,height:20))
                fill(badge,SeePalette.rose);stroke(badge)
                var plus = Path()
                plus.move(to:CGPoint(x:17,y:44));plus.addLine(to:CGPoint(x:17,y:54));plus.move(to:CGPoint(x:12,y:49));plus.addLine(to:CGPoint(x:22,y:49));stroke(plus)
            case .speech:
                var back = Path()
                back.move(to:CGPoint(x:29,y:10));back.addLine(to:CGPoint(x:47,y:10));back.addQuadCurve(to:CGPoint(x:55,y:18),control:CGPoint(x:55,y:10));back.addLine(to:CGPoint(x:55,y:32))
                back.addQuadCurve(to:CGPoint(x:47,y:40),control:CGPoint(x:55,y:40));back.addLine(to:CGPoint(x:43,y:40));back.addLine(to:CGPoint(x:43,y:46));back.addLine(to:CGPoint(x:35,y:40));back.addLine(to:CGPoint(x:29,y:40))
                back.addQuadCurve(to:CGPoint(x:21,y:32),control:CGPoint(x:21,y:40));back.addLine(to:CGPoint(x:21,y:18));back.addQuadCurve(to:CGPoint(x:29,y:10),control:CGPoint(x:21,y:10));back.closeSubpath()
                fill(back,SeePalette.surface);stroke(back)
                var front = Path()
                front.move(to:CGPoint(x:17,y:23));front.addLine(to:CGPoint(x:36,y:23));front.addQuadCurve(to:CGPoint(x:44,y:31),control:CGPoint(x:44,y:23));front.addLine(to:CGPoint(x:44,y:41))
                front.addQuadCurve(to:CGPoint(x:36,y:49),control:CGPoint(x:44,y:49));front.addLine(to:CGPoint(x:24,y:49));front.addLine(to:CGPoint(x:16,y:56));front.addLine(to:CGPoint(x:16,y:49))
                front.addQuadCurve(to:CGPoint(x:8,y:41),control:CGPoint(x:8,y:49));front.addLine(to:CGPoint(x:8,y:31));front.addQuadCurve(to:CGPoint(x:17,y:23),control:CGPoint(x:8,y:23));front.closeSubpath()
                fill(front,SeePalette.sage);stroke(front)
                for x in [16,24,32] { fill(Path(ellipseIn:CGRect(x:x,y:34,width:4,height:4)),SeePalette.ink) }
                var text = Path();text.move(to:CGPoint(x:31,y:18));text.addLine(to:CGPoint(x:45,y:18));stroke(text)
            case .headphone:
                var band = Path()
                band.move(to:CGPoint(x:11,y:36));band.addLine(to:CGPoint(x:11,y:28));band.addCurve(to:CGPoint(x:53,y:28),control1:CGPoint(x:11,y:1),control2:CGPoint(x:53,y:1));band.addLine(to:CGPoint(x:53,y:36))
                band.addLine(to:CGPoint(x:47,y:36));band.addLine(to:CGPoint(x:47,y:28));band.addCurve(to:CGPoint(x:17,y:28),control1:CGPoint(x:47,y:10),control2:CGPoint(x:17,y:10));band.addLine(to:CGPoint(x:17,y:36));band.closeSubpath()
                fill(band,SeePalette.surface);stroke(band)
                for x in [8,44] {
                    let cup = Path(roundedRect:CGRect(x:x,y:30,width:12,height:22),cornerRadius:6)
                    fill(cup,SeePalette.rose);stroke(cup)
                }
                var waves = Path()
                for (x,top,bottom) in [(27,33,42),(32,28,47),(37,33,42)] { waves.move(to:CGPoint(x:x,y:top));waves.addLine(to:CGPoint(x:x,y:bottom)) }
                stroke(waves)
            case .folder:
                var folder = Path()
                folder.move(to:CGPoint(x:8,y:22));folder.addLine(to:CGPoint(x:8,y:17));folder.addQuadCurve(to:CGPoint(x:14,y:11),control:CGPoint(x:8,y:11))
                folder.addLine(to:CGPoint(x:27,y:11));folder.addLine(to:CGPoint(x:33,y:18));folder.addLine(to:CGPoint(x:50,y:18));folder.addQuadCurve(to:CGPoint(x:56,y:24),control:CGPoint(x:56,y:18))
                folder.addLine(to:CGPoint(x:56,y:47));folder.addQuadCurve(to:CGPoint(x:50,y:53),control:CGPoint(x:56,y:53));folder.addLine(to:CGPoint(x:14,y:53));folder.addQuadCurve(to:CGPoint(x:8,y:47),control:CGPoint(x:8,y:53));folder.closeSubpath()
                fill(folder,SeePalette.oat);stroke(folder)
                let paper = Path(roundedRect:CGRect(x:15,y:22,width:34,height:23),cornerRadius:3);fill(paper,SeePalette.surface);stroke(paper)
                let front = Path(roundedRect:CGRect(x:8,y:31,width:48,height:22),cornerRadius:6);fill(front,SeePalette.rose);stroke(front)
            case .calendar:
                let paper = Path(roundedRect:CGRect(x:10,y:14,width:44,height:41),cornerRadius:8);fill(paper,SeePalette.surface);stroke(paper)
                let header = Path(roundedRect:CGRect(x:11,y:15,width:42,height:13),cornerRadius:6);fill(header,SeePalette.oat)
                var binding = Path()
                for x in [21,43] { binding.move(to:CGPoint(x:x,y:9));binding.addLine(to:CGPoint(x:x,y:20)) }
                binding.move(to:CGPoint(x:11,y:28));binding.addLine(to:CGPoint(x:53,y:28));stroke(binding)
                for x in [20,30,40] { for y in [35,44] { fill(Path(roundedRect:CGRect(x:x,y:y,width:4,height:4),cornerRadius:1),SeePalette.ink) } }
            case .clipboard,.memo:
                let page = Path(roundedRect:CGRect(x:14,y:12,width:36,height:44),cornerRadius:6);fill(page,SeePalette.surface);stroke(page)
                if artwork == .clipboard {
                    let clip = Path(roundedRect:CGRect(x:23,y:8,width:18,height:10),cornerRadius:4);fill(clip,SeePalette.oat);stroke(clip)
                } else {
                    let tab = Path(roundedRect:CGRect(x:23,y:9,width:18,height:7),cornerRadius:2);fill(tab,SeePalette.rose)
                }
                for y in [27,36,45] {
                    var line = Path()
                    if artwork == .clipboard {
                        line.move(to:CGPoint(x:19,y:y));line.addLine(to:CGPoint(x:22,y:y+3));line.addLine(to:CGPoint(x:26,y:y-3));line.move(to:CGPoint(x:32,y:y))
                    } else { line.move(to:CGPoint(x:22,y:y)) }
                    line.addLine(to:CGPoint(x:42,y:y));stroke(line)
                }
            case .shield:
                var shield = Path()
                shield.move(to:CGPoint(x:32,y:8));shield.addLine(to:CGPoint(x:51,y:15));shield.addLine(to:CGPoint(x:49,y:33))
                shield.addQuadCurve(to:CGPoint(x:32,y:56),control:CGPoint(x:48,y:47));shield.addQuadCurve(to:CGPoint(x:15,y:33),control:CGPoint(x:16,y:47));shield.addLine(to:CGPoint(x:13,y:15));shield.closeSubpath()
                fill(shield,SeePalette.surface);stroke(shield)
                var check = Path();check.move(to:CGPoint(x:23,y:31));check.addLine(to:CGPoint(x:30,y:38));check.addLine(to:CGPoint(x:42,y:25));stroke(check)
                fill(Path(ellipseIn:CGRect(x:46,y:44,width:10,height:10)),SeePalette.rose)
            case .compass:
                let face = Path(ellipseIn:CGRect(x:9,y:9,width:46,height:46));fill(face,SeePalette.surface);stroke(face)
                var needle = Path();needle.move(to:CGPoint(x:40,y:21));needle.addLine(to:CGPoint(x:35,y:36));needle.addLine(to:CGPoint(x:24,y:43));needle.addLine(to:CGPoint(x:29,y:28));needle.closeSubpath();fill(needle,SeePalette.sky);stroke(needle)
                fill(Path(ellipseIn:CGRect(x:30,y:30,width:4,height:4)),SeePalette.ink)
            case .books:
                var book = Path()
                book.move(to:CGPoint(x:9,y:15));book.addQuadCurve(to:CGPoint(x:32,y:18),control:CGPoint(x:22,y:10));book.addQuadCurve(to:CGPoint(x:55,y:15),control:CGPoint(x:42,y:10));book.addLine(to:CGPoint(x:55,y:49))
                book.addQuadCurve(to:CGPoint(x:32,y:52),control:CGPoint(x:43,y:44));book.addQuadCurve(to:CGPoint(x:9,y:49),control:CGPoint(x:21,y:44));book.closeSubpath();fill(book,SeePalette.surface);stroke(book)
                var pages = Path();pages.move(to:CGPoint(x:32,y:18));pages.addLine(to:CGPoint(x:32,y:51))
                for y in [26,33,40] { pages.move(to:CGPoint(x:16,y:y));pages.addLine(to:CGPoint(x:25,y:y+1));pages.move(to:CGPoint(x:39,y:y+1));pages.addLine(to:CGPoint(x:48,y:y)) };stroke(pages)
            case .watch:
                let strap = Path(roundedRect:CGRect(x:24,y:5,width:16,height:54),cornerRadius:6);fill(strap,SeePalette.rose);stroke(strap)
                let face = Path(roundedRect:CGRect(x:16,y:17,width:32,height:32),cornerRadius:10);fill(face,SeePalette.surface);stroke(face)
                var hands = Path();hands.move(to:CGPoint(x:32,y:25));hands.addLine(to:CGPoint(x:32,y:33));hands.addLine(to:CGPoint(x:39,y:37));stroke(hands)
            case .campus:
                let building = Path(roundedRect:CGRect(x:12,y:22,width:40,height:33),cornerRadius:4);fill(building,SeePalette.surface);stroke(building)
                var roof = Path();roof.move(to:CGPoint(x:8,y:23));roof.addLine(to:CGPoint(x:32,y:9));roof.addLine(to:CGPoint(x:56,y:23));roof.closeSubpath();fill(roof,SeePalette.oat);stroke(roof)
                let door = Path(roundedRect:CGRect(x:27,y:39,width:10,height:16),cornerRadius:3);fill(door,SeePalette.rose);stroke(door)
                for x in [19,39] { let window = Path(roundedRect:CGRect(x:x,y:29,width:6,height:7),cornerRadius:1);fill(window,SeePalette.sky);stroke(window) }
            }
        }
    }
}

struct SeeHero:View {
    let title:String
    let detail:String
    let artwork:SeeArtwork
    var eyebrow:String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        HStack(alignment:.center,spacing:18) {
            VStack(alignment:.leading,spacing:10) {
                if let eyebrow { Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent) }
                Text(title).font(.system(.title2,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                Text(detail).font(.subheadline).foregroundStyle(SeePalette.secondary).fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading)
            if !typeSize.isAccessibilitySize { SeeArtworkView(artwork:artwork,size:86).rotationEffect(.degrees(-5)) }
        }.padding(.vertical,12).accessibilityElement(children:.contain)
    }
}

struct SeeToolRow:View {
    let title:String
    let detail:String
    let artwork:SeeArtwork
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        HStack(spacing:14) {
            if !typeSize.isAccessibilitySize { SeeArtworkView(artwork:artwork,size:48) }
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.headline).foregroundStyle(SeePalette.ink)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.vertical,7)
    }
}

struct SeePrimaryButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth:.infinity,minHeight:48).padding(.horizontal,14).padding(.vertical,4)
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .background(enabled ? SeePalette.button.opacity(configuration.isPressed ? 0.82 : 1) : Color(.tertiarySystemFill),in:RoundedRectangle(cornerRadius:18))
    }
}
struct SeeSecondaryButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity,minHeight:46).padding(.horizontal,14).padding(.vertical,4)
            .foregroundStyle(enabled ? Color.seeAccent : Color.secondary)
            .background(SeePalette.soft.opacity(configuration.isPressed ? 0.5 : 1),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(SeePalette.line,lineWidth:1))
    }
}

struct SeeStatusTag:View {
    let title:String
    let symbol:String
    var color:Color = .seeAccent
    var body:some View {
        Label(title,systemImage:symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal,10).padding(.vertical,7).background(SeePalette.oat,in:RoundedRectangle(cornerRadius:9))
    }
}

struct SeeHomeCover:View {
    let journey:CampusJourney?
    let action:()->Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.center,spacing:12) {
                VStack(alignment:.leading,spacing:8) {
                    Label(journey == nil ? "从一件小事开始" : "接着上次",systemImage:"bookmark")
                        .font(.caption.weight(.medium)).foregroundStyle(SeePalette.secondary)
                    Text(journey?.title ?? "安排一件新事情").font(.system(.title3,design:.rounded,weight:.bold)).fixedSize(horizontal:false,vertical:true)
                    if let journey {
                        Label(journey.stage.title,systemImage:journey.stage == .paused ? "pause.circle" : "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption.weight(.medium)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                            .padding(.horizontal,9).padding(.vertical,5).background(SeePalette.sage,in:Capsule())
                    } else {
                        Text("准备材料、记下问题，逐步核对安排。").font(.subheadline).foregroundStyle(SeePalette.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                if !typeSize.isAccessibilitySize { SeeArtworkView(artwork:.campus,size:84).rotationEffect(.degrees(3)) }
            }
            Button(action:action) {
                HStack(spacing:10) {
                    Text(journey == nil ? "开始办事旅程" : "继续办事旅程").font(.headline)
                    Spacer(minLength:0)
                    Image(systemName:"arrow.right").font(.subheadline.weight(.semibold))
                }.foregroundStyle(SeePalette.ink).padding(.horizontal,16).padding(.vertical,14).frame(maxWidth:.infinity,minHeight:48)
                    .background(SeePalette.rose,in:RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain).accessibilityIdentifier("home.journey")
        }.padding(20).padding(.top,4).foregroundStyle(SeePalette.ink)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius:16).fill(SeePalette.surface)
                    JournalRuling().stroke(SeePalette.line.opacity(0.4),lineWidth:0.5).accessibilityHidden(true)
                }.clipShape(RoundedRectangle(cornerRadius:16))
            }
            .background { RoundedRectangle(cornerRadius:16).fill(SeePalette.oat).rotationEffect(.degrees(-1.5)).padding(.horizontal,3).offset(y:3) }
            .shadow(color:SeePalette.ink.opacity(0.06),radius:8,x:0,y:5)
            .overlay(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:2).fill(SeePalette.oat.opacity(0.9)).frame(width:76,height:17)
                    .rotationEffect(.degrees(-5)).offset(x:22,y:-7).accessibilityHidden(true).allowsHitTesting(false)
            }
    }
}

struct SeeJourneyCover:View {
    let journey:CampusJourney
    let next:String
    @Environment(\.dynamicTypeSize) private var typeSize
    private var artwork:SeeArtwork { journey.stage == .communicate ? .speech : journey.stage == .check ? .clipboard : journey.stage == .finished ? .shield : .compass }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:10) {
                    Text(journey.demonstration ? "演示旅程" : "我的办事旅程").font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
                    Text(journey.title).font(.system(.title2,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
                if !typeSize.isAccessibilitySize { SeeArtworkView(artwork:artwork,size:78) }
            }
            HStack { SeeStatusTag(title:journey.stage.title,symbol:journey.stage == .paused ? "pause.circle" : "point.topleft.down.to.point.bottomright.curvepath");Spacer();Text("第 \(journey.revision) 版").font(.caption).foregroundStyle(.secondary) }
            SeeJourneyTimeline(stage:journey.stage)
            VStack(alignment:.leading,spacing:7) {
                Text("接下来").font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
                Text(next).font(.subheadline.weight(.medium)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(SeePalette.sage,in:RoundedRectangle(cornerRadius:18))
        }.padding(.vertical,10)
    }
}

private struct SeeJourneyTimeline:View {
    let stage:JourneyStage
    @Environment(\.dynamicTypeSize) private var typeSize
    private let stages:[JourneyStage] = [.prepare,.communicate,.check,.depart,.followUp,.finished]
    var body:some View {
        if !typeSize.isAccessibilitySize {
            HStack(alignment:.top,spacing:0) {
                ForEach(stages) { item in
                    VStack(spacing:7) {
                        Image(systemName:item == stage ? "circle.inset.filled" : "circle").font(.caption).foregroundStyle(item == stage ? Color.seeAccent : SeePalette.secondary)
                        Text(item.title).font(.caption2).foregroundStyle(item == stage ? SeePalette.ink : SeePalette.secondary)
                    }.frame(maxWidth:.infinity)
                }
            }.padding(.vertical,8).accessibilityElement(children:.ignore).accessibilityLabel("当前阶段："+stage.title)
        }
    }
}

struct SeeJourneyRow:View {
    let journey:CampusJourney
    var body:some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:journey.stage == .finished ? "checkmark.seal" : journey.stage == .paused ? "pause.circle" : "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title3.weight(.semibold)).foregroundStyle(Color.seeAccent).frame(width:42,height:46).background(SeePalette.soft,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:7) {
                Text(journey.title).font(.headline).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                Text(journey.stage.title).font(.subheadline).foregroundStyle(Color.seeAccent)
                Text(journey.facts.isEmpty ? "先准备材料与要问的问题" : "\(journey.facts.filter(\.isConfirmed).count)/\(journey.facts.count) 项已核对").font(.caption).foregroundStyle(.secondary)
                if journey.demonstration { Text("演示 · 模拟材料").font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top,8)
        }.padding(.vertical,10)
    }
}

struct SeeFactValue:View {
    let fact:JourneyFact
    private var symbol:String { switch fact.kind { case .time:return "calendar";case .place:return "mappin.and.ellipse";case .fee:return "yensign.circle";case .material:return "doc.on.doc";case .other:return "text.bubble" } }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label(fact.kind.title,systemImage:symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Color.seeAccent)
                Spacer()
                Text("第 \(fact.revision) 版").font(.caption).foregroundStyle(.secondary)
            }
            Text(fact.value).font(.system(.largeTitle,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink).textSelection(.enabled)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,minHeight:100,alignment:.leading)
            Label(fact.superseded ? "依据有更新，请重新核对" : fact.isConfirmed ? "我已核对这项信息" : "请与对方一起核对",systemImage:fact.superseded ? "exclamationmark.circle" : fact.isConfirmed ? "checkmark.circle.fill" : "person.2")
                .font(.caption.weight(.semibold)).foregroundStyle(fact.superseded ? Color.orange : Color.seeAccent)
        }.padding(24).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:28))
            .overlay(RoundedRectangle(cornerRadius:28).stroke(SeePalette.line,lineWidth:1))
    }
}

struct SeeEmptyState:View {
    let title:String
    let detail:String
    let artwork:SeeArtwork
    var body:some View {
        VStack(spacing:14) {
            SeeArtworkView(artwork:artwork,size:100)
            Text(title).font(.system(.title3,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
        }.padding(.vertical,28).padding(.horizontal,20).frame(maxWidth:.infinity)
    }
}
