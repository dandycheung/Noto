//
//  Document.swift
//  TipTyper
//
//  Created by Bruno Philipe on 14/1/17.
//  Copyright © 2017 Bruno Philipe. All rights reserved.
//

import Cocoa

internal protocol DocumentDelegate
{
	func encodingDidChange(document: Document, newEncoding: String.Encoding)
}

class Document: NSDocument
{
	private var loadedString: String? = nil
	private var usedEncoding: String.Encoding = .utf8

	private var pendingOperations = [PendingOperation]()

	var delegate: DocumentDelegate? = nil

	override init()
	{
	    super.init()

		// Add your subclass-specific initialization here.
	}

	override func makeWindowControllers()
	{
		super.makeWindowControllers()

		window?.setup(self)
		sendDataToWindow()
	}

	var window: DocumentWindow?
	{
		get
		{
			return windowControllers.first?.window as? DocumentWindow
		}
	}

	var encoding: String.Encoding
	{
		return usedEncoding
	}

	override class func autosavesInPlace() -> Bool
	{
		return true
	}

	override var windowNibName: String?
	{
		// Returns the nib file name of the document
		// If you need to use a subclass of NSWindowController or if your document supports multiple NSWindowControllers,
		// you should remove this property and override -makeWindowControllers instead.
		return "Document"
	}

	override var shouldRunSavePanelWithAccessoryView: Bool
	{
		return false
	}

	override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool
	{
		if let operation = popFirstPendingOperationOf(type: SavePanelMessageOperation.self)
		{
			let label = NSTextField(string: operation.message)
			label.allowsEditingTextAttributes = false
			label.isSelectable = false
			label.isBordered = false
			label.drawsBackground = false

			savePanel.accessoryView = label
		}

		return super.prepareSavePanel(savePanel)
	}

	override func data(ofType typeName: String) throws -> Data
	{
		if let data = window?.text.data(using: usedEncoding)
		{
			return data
		}

		throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
	}

	override func write(to url: URL, ofType typeName: String) throws
	{
		let oldEncoding = self.usedEncoding

		do
		{
			if let operation = popFirstPendingOperationOf(type: ChangeEncodingNotificationOperation.self)
			{
				self.usedEncoding = operation.encoding

				try data(ofType: typeName).write(to: url)

				self.delegate?.encodingDidChange(document: self, newEncoding: usedEncoding)
			}
			else
			{
				try data(ofType: typeName).write(to: url)
			}
		}
		catch let error
		{
			self.usedEncoding = oldEncoding
			throw error
		}
	}

	override func revert(toContentsOf url: URL, ofType typeName: String) throws
	{
		if url.isFileURL
		{
			try read(from: url, ofType: typeName)
			sendDataToWindow()
			updateChangeCount(.changeCleared)
		}
		else
		{
			throw NSError(domain: kTipTyperErrorDomain, code: 1020, userInfo: [NSLocalizedDescriptionKey: "Could not restore file"])
		}
	}

	override func read(from url: URL, ofType typeName: String) throws
	{
		if let (loadedString, usedEncoding) = EncodingTool.loadStringFromURL(url)
		{
			self.loadedString = loadedString
			self.usedEncoding = usedEncoding
		}
		else
		{
			throw NSError(domain: kTipTyperErrorDomain, code: 1010, userInfo: [NSLocalizedDescriptionKey: "Could not load file"])
		}
	}

	override func printOperation(withSettings printSettings: [String: Any]) throws -> NSPrintOperation
	{
		if let window = self.window
		{
			let printInfo = self.printInfo.copy() as! NSPrintInfo
			printInfo.dictionary().addEntries(from: printSettings)

			let printView = PrintingView(printInfo: printInfo)
			if let storage = window.textView.textStorage?.string
			{
				let textStorage = NSTextStorage(string: storage)
				printView.textView.layoutManager?.replaceTextStorage(textStorage)
			}

			printView.textView.textColor = NSColor.black
			printView.textView.font = Preferences.instance.editorFont
			printView.textView.lineCounterView?.font = Preferences.instance.lineCounterFont
			printView.textView.setLayoutOrientation(window.textView.layoutOrientation)
			
			if let lineCounterView = printView.textView.lineCounterView
			{
				lineCounterView.backgroundColor = NSColor.white
				lineCounterView.textColor = NSColor.black
			}

			let accessoryContoller = PrintAccessoryViewController.make()
			let printOperation = NSPrintOperation(view: printView, printInfo: printInfo)
			printOperation.showsPrintPanel = true
			printOperation.showsProgressPanel = true
			printOperation.jobTitle = window.textView.printJobTitle

			var originalSize = window.textView.frame.size

			if window.textView.enclosingScrollView?.rulersVisible == true, let lineCounterView = window.textView.lineCounterView
			{
				originalSize.width += lineCounterView.frame.width
			}

			printView.originalSize = originalSize
			printView.printPanelAccessoryController = accessoryContoller

			let printPanel = printOperation.printPanel
			printPanel.options = [
				printPanel.options,
				.showsPaperSize,
				.showsOrientation,
				.showsScaling
			]

			printPanel.addAccessoryController(accessoryContoller)

			return printOperation
		}
		else
		{
			throw NSError(domain: kTipTyperErrorDomain,
						  code: 2001,
						  userInfo: [NSLocalizedDescriptionKey: "Could not retrieve data to print"])
		}
	}

	private func sendDataToWindow()
	{
		undoManager?.disableUndoRegistration()

		if let string = loadedString
		{
			window?.text = string
			loadedString = nil
		}

		undoManager?.enableUndoRegistration()
	}

	fileprivate func reopenFileAskingForEncoding()
	{
		if let fileURL = self.fileURL
		{
			repeat
			{
				if let newEncoding = EncodingTool.showEncodingPicker()
				{
					if let newString = try? String(contentsOf: fileURL, encoding: newEncoding)
					{
						self.loadedString = newString
						self.usedEncoding = newEncoding

						sendDataToWindow()
						updateChangeCount(.changeCleared)
						return
					}
				}
				else
				{
					// User clicked cancel
					return
				}
			}
			while true
		}
	}

	fileprivate func saveFileAskingForEncoding(_ sender: Any?)
	{
		if let newEncoding = EncodingTool.showEncodingPicker()
		{
			self.pendingOperations.append(SavePanelMessageOperation(message: "Saving file with new encoding: \(newEncoding.description)"))
			self.pendingOperations.append(ChangeEncodingNotificationOperation(encoding: newEncoding))

			saveAs(sender)
		}
	}

	private func popFirstPendingOperationOf<T: PendingOperation>(type: T.Type) -> T?
	{
		if let index = pendingOperations.index(where: { stored in stored is T })
		{
			let operation = pendingOperations[index]
			pendingOperations.remove(at: index)
			return operation as? T
		}

		return nil
	}
}

extension Document
{
	@IBAction func reopenWithEncoding(_ sender: Any?)
	{
		reopenFileAskingForEncoding()
	}

	@IBAction func saveAsWithEncoding(_ sender: Any?)
	{
		saveFileAskingForEncoding(sender)
	}
}

private protocol PendingOperation {}

private struct SavePanelMessageOperation: PendingOperation
{
	var message: String
}

private struct ChangeEncodingNotificationOperation: PendingOperation
{
	var encoding: String.Encoding
}
