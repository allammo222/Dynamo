//
//  Servers.swift
//  Dynamo
//
//  Created by John Holdsworth on 11/06/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//
//  $Id: //depot/Dynamo/Sources/Servers.swift#1 $
//
//  Repo: https://github.com/johnno1962/Dynamo
//

import Foundation

// MARK: Private queues and missing IP functions

let dynamoRequestQueue = dispatch_queue_create( "DynamoRequestThread", DISPATCH_QUEUE_CONCURRENT )

let INADDR_ANY = in_addr_t(0)
let htons = Int(OSHostByteOrder()) == OSLittleEndian ? _OSSwapInt16 : { $0 }
let ntohs = htons

/**
     Result returned by a swiftlet to indicate whether it has handled the request. If a "Content-Length"
     header has been provided the connection can be reused in the HTTP/1.1 protocol and the connection
     will be kept open and recycled.
 */

@objc public enum DynamoProcessed: Int {
    case
        NotProcessed, // does not recogise the request
        Processed, // has processed the request
        ProcessedAndReusable // "" and connection may be reused
}

/**
     Basic protocol that switlets implement to pick up and process requests from a client.
 */

@objc public protocol DynamoSwiftlet {

    /**
        each request is presented ot each swiftlet until one indicates it has processed the request
     */
    @objc func process( httpClient: DynamoHTTPConnection ) -> DynamoProcessed
}

// MARK: Basic http: Web server

/**
     Basic http protocol web server running on the specified port. Requests are presented to each of a set
     of swiftlets provided in a connecton thread until one is encountered that has processed the request.
 */

public class DynamoWebServer: NSObject, NSStreamDelegate {

    private let swiftlets: [DynamoSwiftlet]
    private let serverSocket: Int32

    /** port allocated for server if specified as 0 */
    public var serverPort: UInt16 = 0

    func wrapConnection( clientSocket: Int32 ) -> DynamoHTTPConnection? {
        return DynamoHTTPConnection( clientSocket: clientSocket )
    }

    /** basic initialiser for Swift web server processing using array of swiftlets */
    public convenience init?( portNumber: UInt16, swiftlets: [DynamoSwiftlet], localhostOnly: Bool = false ) {

        self.init( portNumber, swiftlets: swiftlets, localhostOnly: localhostOnly )

        runConnectionHandler( httpConnectionHander )
    }

    init?( _ portNumber: UInt16, swiftlets: [DynamoSwiftlet], localhostOnly: Bool ) {

        self.swiftlets = swiftlets

        var ip4addr = sockaddr_in(sin_len: UInt8(sizeof(sockaddr_in)),
            sin_family: sa_family_t(AF_INET),
            sin_port: htons( portNumber ),
            sin_addr: in_addr( s_addr: INADDR_ANY ),
            sin_zero: (Int8(0),Int8(0),Int8(0),Int8(0),Int8(0),Int8(0),Int8(0),Int8(0)))

        if localhostOnly {
            inet_aton( "127.0.0.1", &ip4addr.sin_addr )
        }

        serverSocket = socket( Int32(ip4addr.sin_family), SOCK_STREAM, 0 )
        var yes: u_int = 1, yeslen = socklen_t(sizeof(yes.dynamicType))
        var addrLen = socklen_t(sizeof(ip4addr.dynamicType))

        super.init()

        if serverSocket < 0 {
            dynamoStrerror( "Could not get server socket" )
        }
        else if setsockopt( serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, yeslen ) < 0 {
            dynamoStrerror( "Could not set SO_REUSEADDR" )
        }
        else if Darwin.bind( serverSocket, sockaddr_cast(&ip4addr), socklen_t(ip4addr.sin_len) ) < 0 {
            dynamoStrerror( "Could not bind service socket on port \(portNumber)" )
        }
        else if listen( serverSocket, 100 ) < 0 {
            dynamoStrerror( "Server socket would not listen" )
        }
        else if getsockname( serverSocket, sockaddr_cast(&ip4addr), &addrLen ) == 0 {
            serverPort = ntohs( ip4addr.sin_port )
            let s = self.dynamicType === DynamoSSLWebServer.self ? "s" : ""
            dynamoLog( "Server available on http\(s)://localhost:\(serverPort)" )
            return
        }

        return nil
    }

    func runConnectionHandler( connectionHandler: (Int32) -> Void ) {
        dispatch_async( dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), {
            while self.serverSocket >= 0 {

                let clientSocket = accept( self.serverSocket, nil, nil )

                if clientSocket >= 0 {
                    dispatch_async( dynamoRequestQueue, {
                        connectionHandler( clientSocket )
                    } )
                }
                else {
                    NSThread.sleepForTimeInterval( 0.5 )
                }
            }
        } )
    }

    func httpConnectionHander( clientSocket: Int32 ) {

        if let httpClient = self.wrapConnection( clientSocket ) {

            while httpClient.readHeaders() {
                var processed = false

                for swiftlet in swiftlets {

                    switch swiftlet.process( httpClient ) {
                    case .NotProcessed:
                        continue
                    case .Processed:
                        return
                    case .ProcessedAndReusable:
                        httpClient.flush()
                        processed = true
                        break
                    }

                    break
                }

                if !processed {
                    httpClient.status = 400
                    httpClient.response( "Invalid request: \(httpClient.method) \(httpClient.path) \(httpClient.version)" )
                    return
                }
            }
        }
    }

}

// MARK: SSL https: Web Server

/**
    Subclass of DynamoWebServer for accepting https: SSL encoded requests. Create a proxy on the provided
    port to a surrogate DynamoWebServer on a random port on the localhost to actually process the requests.
*/

public class DynamoSSLWebServer: DynamoWebServer {

    private let certs: [AnyObject]

    override func wrapConnection( clientSocket: Int32 ) -> DynamoHTTPConnection? {
        return DynamoSSLConnection( sslSocket: clientSocket, certs: certs )
    }

    /**
        default initialiser for SSL server. Can proxy a "surrogate" non-SSL server given it's URL
    */
    public init?( portNumber: UInt16, swiftlets: [DynamoSwiftlet] = [], certs: [AnyObject], surrogate: String? = nil ) {

        self.certs = certs

        super.init( portNumber, swiftlets: swiftlets, localhostOnly: false )

        if surrogate == nil {
            runConnectionHandler( httpConnectionHander )
        }
        else if let surrogateURL = NSURL( string: surrogate! ) {
            runConnectionHandler( sslProxyHandler( surrogateURL ) )
        }
        else {
            dynamoLog( "Invalid surrogate URL: \(surrogate)" )
        }
    }

    func sslProxyHandler( surrogateURL: NSURL )( clientSocket: Int32 ) {
        if let sslConnection = wrapConnection( clientSocket ),
            localConnection = DynamoHTTPConnection( url: surrogateURL ) {
                DynamoSelector.relay( "surrogate", from: sslConnection, to: localConnection, dynamoTrace )
        }
    }

}

class DynamoSSLConnection: DynamoHTTPConnection, NSStreamDelegate {

    let inputStream: NSInputStream
    let outputStream: NSOutputStream

    init?( sslSocket: Int32, certs: [AnyObject]? ) {

        var readStream:  Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocket( nil, sslSocket, &readStream, &writeStream )

        inputStream = readStream!.takeRetainedValue()
        outputStream = writeStream!.takeRetainedValue()

        super.init( clientSocket: sslSocket )

        inputStream.open()
        outputStream.open()

        if certs != nil {
            let sslSettings: [NSString:AnyObject] = [
                kCFStreamSSLIsServer: NSNumber( bool: true ),
                kCFStreamSSLLevel: kCFStreamSSLLevel,
                kCFStreamSSLCertificates: certs!
            ]

            CFReadStreamSetProperty( inputStream, kCFStreamPropertySSLSettings, sslSettings )
            CFWriteStreamSetProperty( outputStream, kCFStreamPropertySSLSettings, sslSettings )
        }
    }

    override var hasBytesAvailable: Bool {
        return inputStream.hasBytesAvailable
    }

    override func _read( buffer: UnsafeMutablePointer<Void>, count: Int ) -> Int {
        return inputStream.read( UnsafeMutablePointer<UInt8>(buffer), maxLength: count )
    }

    override func _write( buffer: UnsafePointer<Void>, count: Int ) -> Int {
        return outputStream.write( UnsafePointer<UInt8>(buffer), maxLength: count )
    }

    override func receive( buffer: UnsafeMutablePointer<Void>, count: Int ) -> Int? {
        return inputStream.hasBytesAvailable ? _read( buffer, count: count ) :  nil
    }

    override func forward( buffer: UnsafePointer<Void>, count: Int ) -> Int? {
        return outputStream.hasSpaceAvailable ? _write( buffer, count: count ) : nil
    }

    deinit {
        flush()
        outputStream.close()
        inputStream.close()
    }

}

// MARK: Functions

func sockaddr_cast(p: UnsafeMutablePointer<Void>) -> UnsafeMutablePointer<sockaddr> {
    return UnsafeMutablePointer<sockaddr>(p)
}

func sockaddr_in_cast(p: UnsafeMutablePointer<sockaddr>) -> UnsafeMutablePointer<sockaddr_in> {
    return UnsafeMutablePointer<sockaddr_in>(p)
}

/** default tracer for frequent messages */
public func dynamoTrace<T>( msg: T ) {
    print( msg )
}

func dynamoLog<T>( msg: T ) {
    NSLog( "DynamoWebServer: %@", "\(msg)" )
}

func dynamoStrerror( msg: String ) {
    dynamoLog( "\(msg) - \( String( UTF8String: strerror(errno) )! )" )
}