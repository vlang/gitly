module api

pub struct ApiErrorResponse {
	success bool
	message string
}

pub struct ApiResponse {
	success bool
	message string
}

pub struct ApiSuccessResponse[T] {
	success bool
	result  T
}
