import SwiftUI
import PDFKit
import UIKit

struct ImportPayload: Identifiable { let id = UUID();let data:Data;let pdf:Bool }
struct ImportPreparationView: View {
    let payload:ImportPayload
    let acceptImage:(Data)->Void
    let acceptPDF:(Data,[Int])->Void
    @Environment(\.dismiss) private var dismiss
    @State private var rotation = 0
    @State private var left = 0.0
    @State private var right = 1.0
    @State private var top = 0.0
    @State private var bottom = 1.0
    @State private var pages = Set<Int>()
    @State private var error:String?
    private let document:PDFDocument?
    init(payload:ImportPayload,acceptImage:@escaping (Data)->Void,acceptPDF:@escaping (Data,[Int])->Void) {
        self.payload = payload;self.acceptImage = acceptImage;self.acceptPDF = acceptPDF;self.document = payload.pdf ? PDFDocument(data:payload.data) : nil
    }
    var body:some View {
        NavigationStack {
            List {
                if payload.pdf {
                    pdfContent
                } else if let image = transformedImage() {
                    Section("先调整识字范围") {
                        Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:330).accessibilityLabel("裁切后的图片预览")
                        Button("顺时针旋转 90°",systemImage:"rotate.right") { rotation = (rotation+1)%4;left=0;right=1;top=0;bottom=1 }
                        cropSlider("左边界",value:$left,range:0...max(0,right-0.05))
                        cropSlider("右边界",value:$right,range:min(1,left+0.05)...1)
                        cropSlider("上边界",value:$top,range:0...max(0,bottom-0.05))
                        cropSlider("下边界",value:$bottom,range:min(1,top+0.05)...1)
                        Button("重置裁切") { left=0;right=1;top=0;bottom=1 }
                        Text("只识别预览中的区域；图片仅在本次导入中使用。").font(.caption).foregroundStyle(.secondary)
                        Button("用这张图片识字") {
                            guard let data = image.jpegData(compressionQuality:0.9) else { error = "图片无法处理";return };acceptImage(data);dismiss()
                        }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                    }
                } else { Text("图片无法打开，请重新选择。") }
                if let error { Text(error).foregroundStyle(.red) }
            }.seePageCanvas().navigationTitle(payload.pdf ? "选择 PDF 页面" : "裁切与旋转").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.modifier(WorkroomPrivacy())
    }
    @ViewBuilder private var pdfContent:some View {
        if let document,!document.isLocked,document.pageCount > 0,document.pageCount <= 500 {
            Section {
                Text("共 \(document.pageCount) 页，已选 \(pages.count) / 12 页。只读取所选页面。")
                HStack { Button("选择前 12 页") { pages = Set(0..<min(12,document.pageCount)) };Spacer();Button("清空") { pages = [] } }
                Button("读取选中页面") { acceptPDF(payload.data,pages.sorted());dismiss() }.disabled(pages.isEmpty).buttonStyle(.borderedProminent).tint(SeePalette.button)
            }
            Section("页面预览") {
                ForEach(0..<document.pageCount,id:\.self) { index in
                    Button { if pages.contains(index) { pages.remove(index) } else if pages.count < 12 { pages.insert(index) } } label: {
                        HStack(alignment:.top) {
                            Image(systemName:pages.contains(index) ? "checkmark.circle.fill" : "circle")
                            if let page = document.page(at:index) {
                                Image(uiImage:page.thumbnail(of:CGSize(width:70,height:95),for:.mediaBox)).resizable().scaledToFit().frame(width:55,height:80)
                                VStack(alignment:.leading) { Text("第 \(index+1) 页").font(.headline);Text(page.string.map { String($0.prefix(70)) } ?? "扫描页，将在本机识字").font(.caption).lineLimit(3).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.buttonStyle(.plain)
                }
            }
        } else { Text("PDF 加密、为空或超过 500 页，无法预览。请先拆分文件。") }
    }
    private func cropSlider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>) -> some View {
        VStack(alignment:.leading) { Text(title).font(.caption);Slider(value:value,in:range).accessibilityLabel(title) }
    }
    private func transformedImage() -> UIImage? {
        guard let raw = UIImage(data:payload.data) else { return nil }
        // Downsample before rendering to keep large screenshots within a bounded working size.
        let scale = min(1,2400/max(raw.size.width,raw.size.height)),base = CGSize(width:raw.size.width*scale,height:raw.size.height*scale)
        let size = rotation%2 == 0 ? base : CGSize(width:base.height,height:base.width)
        let format = UIGraphicsImageRendererFormat();format.scale=1
        let rotated = UIGraphicsImageRenderer(size:size,format:format).image { context in
            context.cgContext.translateBy(x:size.width/2,y:size.height/2);context.cgContext.rotate(by:CGFloat(rotation) * .pi / 2)
            raw.draw(in:CGRect(x:-base.width/2,y:-base.height/2,width:base.width,height:base.height))
        }
        let rect = CGRect(x:left*size.width,y:top*size.height,width:(right-left)*size.width,height:(bottom-top)*size.height).integral
        guard let cg = rotated.cgImage?.cropping(to:rect) else { return nil };return UIImage(cgImage:cg)
    }
}
