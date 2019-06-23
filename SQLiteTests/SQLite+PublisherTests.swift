import XCTest
import Combine
@testable import SQLite

class SQLitePublisherTests: XCTestCase {
    var database: SQLite.Database!

    override func setUp() {
        super.setUp()
        database = try! SQLite.Database(path: ":memory:")

        try! database.execute(raw: Person.createTable)
        try! database.execute(raw: Pet.createTable)
        let encoder = SQLite.Encoder(database)
        try! encoder.encode([_person1, _person2], using: Person.insert)
        try! encoder.encode([_pet1, _pet2], using: Pet.insert)
    }

    override func tearDown() {
        super.tearDown()
        database.close()
    }

    func testReceivesCompletionWithErrorGivenInvalidSQL() {
        let expectation = self.expectation(description: "Completes with error")
        let publisher = database.publisher("NOPE;")
        let receiveCompletion: (Subscribers.Completion<Error>) -> Void = { completion in
            switch completion {
            case .finished:
                XCTFail("Should have completed with error")
            case .failure(let error):
                guard case SQLite.Error.onPrepareStatement = error else {
                    return XCTFail("Incorrect error: \(error)")
                }
            }
            expectation.fulfill()
        }
        let receiveValue: (Array<SQLiteRow>) -> Void = { rows in
            XCTFail("Should have completed with error, not received \(rows)")
            expectation.fulfill()
        }
        let subscriber = publisher.sink(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
        waitForExpectations(timeout: 0.5)
        subscriber.cancel()
    }

    func testCancellingSinkCancelsSubscriptions() {
        let publisher: AnyPublisher<Array<Person>, Error> = database.publisher(Person.getAll)
        let sink = self.sink(for: publisher, expecting: [[_person1, _person2]])

        self.do({
            sink.cancel()
            try! self.database.write(Person.deleteWithID, arguments: ["id": .text(self._person1.id)])
        }, after: 0.05, thenWait: 0.1)
    }

    func testDeleteAsSQLiteRow() {
        let expectation = self.expectation(description: "Received two notifications")

        let expected: Array<Array<SQLiteRow>> = [
            [_person1.asArguments, _person2.asArguments],
            [_person2.asArguments],
        ]

        let publisher: AnyPublisher<Array<SQLiteRow>, Error> = database.publisher(Person.getAll)
        let sink = self.sink(for: publisher, expecting: expected, expectation: expectation)
        try! database.write(Person.deleteWithID, arguments: ["id": .text(_person1.id)])
        waitForExpectations(timeout: 0.5)
        sink.cancel()
    }

    func testDelete() {
        let expectation = self.expectation(description: "Received two notifications")

        let expected: Array<Array<Person>> = [
            [_person1, _person2],
            [_person2],
        ]

        let publisher: AnyPublisher<Array<Person>, Error> = database.publisher(Person.getAll)
        let sink = self.sink(for: publisher, expecting: expected, expectation: expectation)
        try! database.write(Person.deleteWithID, arguments: ["id": .text(_person1.id)])
        waitForExpectations(timeout: 0.5)
        sink.cancel()
    }

    func testDeleteFirstWhere() {
        let expectation = self.expectation(description: "Received two notifications")
        let publisher: AnyPublisher<Array<Person>, Error> =
            database.publisher(Person.getAll)
                .first(where: { $0.count == 1 })
                .eraseToAnyPublisher()

        let sink = self.sink(for: publisher, shouldFinish: true, expecting: [[_person2]], expectation: expectation)
        try! database.write(Person.deleteWithID, arguments: ["id": .text(_person1.id)])
        waitForExpectations(timeout: 0.5)
        sink.cancel()
    }

    func testDeleteMappedToName() {
        let expectation = self.expectation(description: "Received two notifications")

        let expected: Array<Array<String>> = [
            [_person1.name, _person2.name],
            [_person2.name],
        ]

        let publisher: AnyPublisher<Array<String>, Error> =
            database.publisher(Person.self, Person.getAll)
                .map { $0.map { $0.name } }
                .eraseToAnyPublisher()

        let sink = self.sink(for: publisher, expecting: expected, expectation: expectation)
        try! database.write(Person.deleteWithID, arguments: ["id": .text(_person1.id)])
        waitForExpectations(timeout: 0.5)
        sink.cancel()
    }

    func testInsert() {
        let expectation = self.expectation(description: "Received two notifications")

        let person3 = Person(id: "3", name: "New Human", age: 1, title: "newborn")
        let pet3 = Pet(name: "Camo the Camel", ownerID: person3.id, type: "camel", registrationID: "3")
        let petOwner3 = PetOwner(
            id: person3.id, name: person3.name, age: person3.age, title: person3.title, pet: pet3
        )

        let expected: Array<Array<PetOwner>> = [
            [_petOwner1, _petOwner2],
            [_petOwner1, _petOwner2], // After insert of person
            [_petOwner1, _petOwner2, petOwner3], // After insert of pet
        ]

        let publisher: AnyPublisher<Array<PetOwner>, Error> = database.publisher(PetOwner.self, PetOwner.getAll)

        let sink = self.sink(for: publisher, expecting: expected, expectation: expectation)
        try! database.write(Person.insert, arguments: person3.asArguments)
        try! database.write(Pet.insert, arguments: pet3.asArguments)
        waitForExpectations(timeout: 0.5)
        sink.cancel()
    }
}

extension SQLitePublisherTests {
    private var _person1: Person {
        return Person(id: "1", name: "Anthony", age: 36, title: nil)
    }

    private var _person2: Person {
        return Person(id: "2", name: "Satya", age: 50, title: "CEO")
    }

    private var _pet1: Pet {
        return Pet(name: "Fido", ownerID: "1", type: "dog", registrationID: "1")
    }

    private var _pet2: Pet {
        return Pet(name: "小飞球", ownerID: "2", type: "cat", registrationID: "2")
    }

    private var _petOwner1: PetOwner {
        return PetOwner(id: "1", name: "Anthony", age: 36, title: nil, pet: _pet1)
    }

    private var _petOwner2: PetOwner {
        return PetOwner(id: "2", name: "Satya", age: 50, title: "CEO", pet: _pet2)
    }
}

private extension SQLitePublisherTests {
    func `do`(_ something: @escaping () -> Void, after firstCheckpoint: CFTimeInterval,
              thenWait secondCheckpoint: CFTimeInterval) {
        let start = CACurrentMediaTime()
        func performOrWait(_ block: () -> Void, after seconds: CFTimeInterval) -> Bool {
            guard CACurrentMediaTime() - start >= seconds else { return false }
            block()
            return true
        }

        while performOrWait(something, after: firstCheckpoint) == false {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        while performOrWait({ }, after: secondCheckpoint) == false {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func sink<T: Equatable, E: Error>(
        for publisher: AnyPublisher<Array<T>, E>,
        shouldFinish: Bool = false,
        expecting expected: Array<Array<T>>,
        expectation: XCTestExpectation? = nil)
        -> Subscribers.Sink<AnyPublisher<Array<T>, E>> {
            let receiveCompletion: (Subscribers.Completion<E>) -> Void = { completion in
                guard shouldFinish, case .finished = completion else {
                    XCTFail("Should not receive completion: \(String(describing: completion))")
                    return
                }
            }

            var expected = expected
            let receiveValue: (Array<T>) -> Void = { value in
                let first = expected.removeFirst()
                XCTAssertEqual(first, value)
                if expected.isEmpty {
                    expectation?.fulfill()
                }
            }

            return publisher.sink(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
    }
}
