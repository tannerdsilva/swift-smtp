import Dispatch
import Foundation
import NIO
import NIOExtras
import NIOSSL
import NIOConcurrencyHelpers

fileprivate extension Configuration.Server {
    enum EncryptionHandler {
        case none
        case atBeginning(ChannelHandler)
        case beforeSMTPHandler(ChannelHandler)
    }
    
    func createEncryptionHandlers() throws -> EncryptionHandler {
        switch encryption {
        case .plain: return .none
        case .ssl:
            let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
            return .atBeginning(sslHandler)
        case .startTLS(let mode):
            return .beforeSMTPHandler(StartTLSDuplexHandler(server: self, tlsMode: mode))
        }
    }
}
public final class Mailer {
	public let group:EventLoopGroup
	public let configuration:Configuration
	
	public init(group:EventLoopGroup, configuration:Configuration) {
		self.group = group
		self.configuration = configuration
	}
	
	@discardableResult fileprivate func connectBootstrap(_ promise:EventLoopPromise<Void>, email:Email) throws -> ClientBootstrap {
		let bootstrap = ClientBootstrap(group:group)
			.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value:1)
			.connectTimeout(configuration.connectionTimeOut).channelInitializer { [configuration] in
			do {
				var base64Options: Data.Base64EncodingOptions = []
				if configuration.featureFlags.contains(.maximumBase64LineLength64) {
					base64Options.insert(.lineLength64Characters)
				}
				if configuration.featureFlags.contains(.maximumBase64LineLength76) {
					base64Options.insert(.lineLength76Characters)
				}
				var handlers:[ChannelHandler] = [
					ByteToMessageHandler(LineBasedFrameDecoder()),
					SMTPResponseDecoder(),
					MessageToByteHandler(SMTPRequestEncoder(base64EncodingOptions: base64Options)),
					SMTPHandler(configuration:configuration, email:email, allDonePromise:promise),
				]
			
				switch try configuration.server.createEncryptionHandlers() {
					case .none: break;
					case .atBeginning(let handler):
					handlers.insert(handler, at: handlers.startIndex)
					case .beforeSMTPHandler(let handler):
					handlers.insert(handler, at: handlers.index(before: handlers.endIndex))
				}
				return $0.pipeline.addHandlers(handlers, position:.last)
			} catch let error {
				return $0.eventLoop.makeFailedFuture(error)
			}
		}
		let connectionFuture = bootstrap.connect(host:configuration.server.hostname, port:configuration.server.port)
		connectionFuture.cascadeFailure(to:promise)
		return bootstrap
	}
	
	public func send(email:Email) async throws {
		let promise = group.next().makePromise(of:Void.self)
		try connectBootstrap(promise, email:email)
		return try await promise.futureResult.get()
	}
}
