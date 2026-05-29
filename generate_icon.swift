import Cocoa
import SwiftUI

struct IconView: View {
    var body: some View {
        ZStack {
            // Base Layer: Deep Obsidian Gradient
            RoundedRectangle(cornerRadius: 225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.15, green: 0.15, blue: 0.18), Color(red: 0.05, green: 0.05, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 20)

            // Inner Glass Border
            RoundedRectangle(cornerRadius: 225, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.2), .clear, .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 6)

            // The "Data Stack" (App Version)
            VStack(spacing: 40) {
                // Top Layer (Active / Latest)
                DataSlab(opacity: 0.85, glow: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing), lineWidth: 5)
                    )
                    .offset(x: 40) // Lean right
                
                // Middle Layer
                DataSlab(opacity: 0.4, glow: 10)
                    .offset(x: 20)
                
                // Bottom Layer
                DataSlab(opacity: 0.15, glow: 0)
                    .offset(x: 0)
            }
            .rotationEffect(.degrees(-12)) // Balanced inclination
        }
        .frame(width: 1024, height: 1024)
    }
}

struct DataSlab: View {
    let opacity: Double
    let glow: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: 550, height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(opacity + 0.2), lineWidth: 3)
            )
            .shadow(color: .cyan.opacity(opacity * 0.4), radius: glow)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 15)
    }
}

struct MenuBarIconView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            // Top (Active)
            RoundedRectangle(cornerRadius: 1.2)
                .fill(.black)
                .frame(width: 16, height: 4)
                .offset(x: 2) // Match app icon lean (right)
                
            // Middle
            RoundedRectangle(cornerRadius: 1.2)
                .fill(.black.opacity(0.8))
                .frame(width: 16, height: 4)
                .offset(x: 1)
                
            // Bottom
            RoundedRectangle(cornerRadius: 1.2)
                .fill(.black.opacity(0.5))
                .frame(width: 16, height: 4)
                .offset(x: 0)
        }
        .rotationEffect(.degrees(-12)) // Same inclination as app icon
        .frame(width: 22, height: 22)
        .background(Color.clear)
    }
}

func renderIcon() {
    // 1. App Icon
    let appSize = NSSize(width: 1024, height: 1024)
    let appView = NSHostingView(rootView: IconView())
    appView.frame = NSRect(origin: .zero, size: appSize)
    let appBitmap = appView.bitmapImageRepForCachingDisplay(in: appView.bounds)!
    appView.cacheDisplay(in: appView.bounds, to: appBitmap)
    if let data = appBitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "icon.png"))
        print("App Icon generated: icon.png")
    }
    
    // 2. Menu Bar Icon (Rendered at 128x128 for extreme quality)
    let menuSize = NSSize(width: 128, height: 128)
    let menuView = NSHostingView(rootView: MenuBarIconView().scaleEffect(5)) // Scale up the 22x22 design
    menuView.frame = NSRect(origin: .zero, size: menuSize)
    let menuBitmap = menuView.bitmapImageRepForCachingDisplay(in: menuView.bounds)!
    menuView.cacheDisplay(in: menuView.bounds, to: menuBitmap)
    if let data = menuBitmap.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "menubar_icon_raw.png"))
        print("Menu Bar Icon (Raw) generated: menubar_icon_raw.png")
    }
}

renderIcon()
