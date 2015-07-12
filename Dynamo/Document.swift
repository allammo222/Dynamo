//
//  Document.swift
//  Dynamo
//
//  Created by John Holdsworth on 11/07/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//
//  $Id: //depot/Dynamo/Dynamo/Document.swift#3 $
//
//  Repo: https://github.com/johnno1962/Dynamo
//

import Foundation

// MARK: Default document Swiftlet

/**
Default document mime type/charset
*/

public var dynamoHtmlMimeType = "text/html; charset=utf-8"

/**
Supported mime types by document extension.
*/

public var dynamoMimeTypeMapping = [
    "ico": "image/x-icon",
    "jpeg":"image/jpeg",
    "jpe": "image/jpeg",
    "jpg": "image/jpeg",
    "tiff":"image/tiff",
    "tif": "image/tiff",
    "gif": "image/gif",
    "png": "image/png",
    "bmp": "image/bmp",
    "css": "text/css",
    "htm": dynamoHtmlMimeType,
    "html":dynamoHtmlMimeType,
    "java":"text/plain",
    "json":"application/json",
    "doc": "application/msword",
    "xls": "application/vnd.ms-excel",
    "ppt": "application/vnd.ms-powerpoint",
    "pps": "application/vnd.ms-powerpoint",
    "js":  "application/x-javascript",
    "jse": "application/x-javascript",
    "reg": "application/octet-stream",
    "eps": "application/postscript",
    "ps":  "application/postscript",
    "gz":  "application/x-gzip",
    "hta": "application/hta",
    "jar": "application/zip",
    "zip": "application/zip",
    "pdf": "application/pdf",
    "qt":  "video/quicktime",
    "mov": "video/quicktime",
    "avi": "video/x-msvideo",
    "wav": "audio/x-wav",
    "snd": "audio/basic",
    "mid": "audio/basic",
    "au":  "audio/basic",
    "mpeg":"video/mpeg",
    "mpe": "video/mpeg",
    "mpg": "video/mpeg",
]

/**
Default swiftlet, generally last in the swiftlet chain to serve static documents from the file system.
This is either from the app resources directory for iOS apps or ~/Sites/hostname:port/... on OSX.
*/

public class DynamoDocumentSwiftlet : NSObject, DynamoSwiftlet {

    let fileManager = NSFileManager.defaultManager()
    let documentRoot: String
    let report404: Bool

    /**
        Convenience initialiser taking document root from the resources directory/localhost:port
    */

    public convenience override init() {
        self.init( documentRoot: NSBundle.mainBundle().resourcePath! )
    }

    /**
        Initialiser pecifying documentRoot an whether this is the last Swiftlet and it should report 404
        if a document is not found.
    */

    public init( documentRoot: String, report404: Bool = true ) {
        self.documentRoot = documentRoot
        self.report404 = report404
    }

    private func webDate( date: NSDate ) -> String {
        return webDateFormatter.stringFromDate( date )
    }

    /**
        Look for static documents in directory named affter host(:port) used in url
    */

    public func process( httpClient: DynamoHTTPConnection ) -> DynamoProcessed {

        if httpClient.method == "GET" {

            let siteHost = httpClient.requestHeaders["Host"] ?? "localhost"
            var fullPath = "\(documentRoot)/\(siteHost)"+(httpClient.url.path ?? "/")

            if fileManager.contentsOfDirectoryAtPath( fullPath, error: nil ) != nil {
                fullPath = fullPath.stringByAppendingPathComponent( "index.html" )
            }

            httpClient.contentType = dynamoMimeTypeMapping[fullPath.pathExtension] ?? dynamoHtmlMimeType

            let zippedPath = fullPath+".gz"
            if fileManager.fileExistsAtPath( zippedPath ) {
                httpClient.addHeader( "Content-Encoding", value: "gzip" )
                fullPath = zippedPath
            }

            if var attrs = fileManager.attributesOfItemAtPath( fullPath, error: nil ),
                        lastModified = attrs[NSFileModificationDate] as? NSDate {

                httpClient.addHeader( "Last-Modified", value: webDate( lastModified ) )

                if let since = httpClient.requestHeaders["If-Modified-Since"] {
                    if webDate( lastModified ) == since {
                        httpClient.status = 304
                        httpClient.response( "" )
                        return .ProcessedAndReusable
                    }
                }

                if let data = NSData( contentsOfFile: fullPath ) {
                    httpClient.responseData( data )
                    return .ProcessedAndReusable
                }
            }

            if report404 {
                httpClient.status = 404
                httpClient.response( "<b>File not found:</b> \(fullPath)" )
                dynamoLog( "404 File not Found: \(fullPath)" )
                return .ProcessedAndReusable
            }
        }
        
        return .NotProcessed
    }
    
}