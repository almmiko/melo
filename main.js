function test() {
	let printValue = print('print value');
	print(printValue);
	timeout(function() {
		print('from timeout 3000');
		timeout(function() {
			print('from timeout nested 2000');
		}, 2000);
	}, 3000);
	timeout(function() {
		print('from timeout 1000');
	}, 1000);
};

test();

async function asyncCall() {
	print('calling async js');
	const result = await resolveAfter();
	print(result);
}
asyncCall();
