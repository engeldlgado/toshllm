// ModelSettings.swift
import SwiftUI

struct ModelSettings: View {
    @Binding var model: Model
    @State private var selectedFile: URL?
    
    var body: some View {
        Section(header: Text("Advanced Settings")) {
            HStack {
                Text("Vision Projector:")
                Spacer()
                Button(action: {
                    // Open file browser to select .mmproj file
                }) {
                    Text("Select File")
                }
                .frame(width: 100)
            }
            .padding()
            .onChange(of: selectedFile) { newValue in
                if let selectedFile = selectedFile {
                    model.visionAdapterPath = selectedFile
                }
            }
        }
    }
}

// FileBrowser.swift
import SwiftUI
import SwiftUIFiles

struct FileBrowser: View {
    @State private var selectedFile: URL?
    
    var body: some View {
        VStack {
            Button(action: {
                // Open file browser to select .mmproj file
            }) {
                Text("Select File")
            }
            .frame(width: 100)
            .padding()
            if let selectedFile = selectedFile {
                Text("Selected File: \(selectedFile.lastPathComponent)")
            }
        }
    }
}

// Models.swift
import Foundation

struct Model: Identifiable {
    let id = UUID()
    var name: String
    var visionAdapterPath: URL?
    // ...
}

// ModelValidator.swift
import Foundation

class ModelValidator {
    func validate(model: Model) -> Bool {
        guard let visionAdapterPath = model.visionAdapterPath else {
            return true
        }
        // Check if file exists and has .mmproj extension
        if !FileManager.default.fileExists(atPath: visionAdapterPath.path) || !visionAdapterPath.pathExtension == "mmproj" {
            return false
        }
        // Check if model architecture supports vision adapter
        // ...
        return true
    }
}

// Server.swift
import Foundation

struct Server {
    var visionAdapterPath: URL?
    
    func launch() {
        // ...
        if let visionAdapterPath = visionAdapterPath {
            command += " --mmproj \(visionAdapterPath.path)"
        }
        // ...
    }
}

// Toast.swift
import SwiftUI

struct Toast: View {
    var message: String
    
    var body: some View {
        Text(message)
            .font(.headline)
            .padding()
            .background(Color.yellow)
            .cornerRadius(10)
    }
}